@testable import FilaLog
import Foundation
import Testing

// The ring is the whole of what logging costs `filad`, and `filad` dies at
// 6 MB. What matters is that it never grows, that it evicts whole frames, and
// that a frame straddling the wrap still reads back as itself — the one bug in
// a hand-written ring that shows up as garbage in a log a week later.

/// A capacity that holds a handful of short lines, so eviction and wrapping
/// happen within a few appends instead of a few thousand.
private let smallCapacity = FilaLogRing.headerByteCount + FilaLogRing.maximumMessageByteCount + 256

@Suite("Log ring")
struct RingTests {
    @Test("Reads back what was written")
    func roundTrip() {
        var ring = FilaLogRing(capacityBytes: 64 * 1024)
        ring.append(level: .warning, source: .daemon, message: "guard refused /private/var")
        ring.append(level: .error, source: .app, message: "open failed errno 1")

        let records = ring.records(since: 0)
        #expect(records.count == 2)
        #expect(records[0].sequence == 1)
        #expect(records[0].level == .warning)
        #expect(records[0].source == .daemon)
        #expect(records[0].message == "guard refused /private/var")
        #expect(records[1].sequence == 2)
        #expect(records[1].level == .error)
        #expect(records[1].source == .app)
        #expect(records[1].message == "open failed errno 1")
        #expect(records[0].time <= records[1].time)
        #expect(ring.droppedCount == 0)
    }

    @Test("A cursor returns only what came after it")
    func cursor() {
        var ring = FilaLogRing(capacityBytes: 64 * 1024)
        for index in 1 ... 10 {
            ring.append(level: .info, source: .app, message: "line \(index)")
        }

        #expect(ring.records(since: 0).count == 10)
        #expect(ring.records(since: 7).map(\.message) == ["line 8", "line 9", "line 10"])
        #expect(ring.records(since: 10).isEmpty)
        // A cursor past the end is a client that has seen everything, not an
        // error and not a reset to the beginning.
        #expect(ring.records(since: 999).isEmpty)
    }

    @Test("Never exceeds its capacity, however much is logged")
    func ceiling() {
        var ring = FilaLogRing(capacityBytes: smallCapacity)
        // Far more than fits: the point is that the ceiling holds regardless.
        for index in 1 ... 5000 {
            ring.append(level: .verbose, source: .daemon, message: "list /private/var/mobile entry \(index)")
        }

        let records = ring.records(since: 0)
        #expect(!records.isEmpty)
        // The invariant the 6 MB cap rests on: the bytes in use never pass the
        // allocation, however long the flood runs.
        #expect(ring.usedBytes <= ring.capacityBytes)
        #expect(ring.capacityBytes == smallCapacity)
        #expect(ring.droppedCount == UInt64(5000 - records.count))
    }

    @Test("Evicts oldest first and keeps the newest intact across the wrap")
    func wrapping() {
        var ring = FilaLogRing(capacityBytes: smallCapacity)
        // Odd-length messages so frames land at every offset in the storage,
        // which is what puts a header across the seam.
        for index in 1 ... 400 {
            ring.append(level: .info, source: .app, message: String(repeating: "x", count: index % 37) + "|\(index)")
        }

        let records = ring.records(since: 0)
        #expect(records.last?.sequence == 400)
        #expect(records.last?.message.hasSuffix("|400") == true)
        // Sequences are contiguous and ascending: an eviction that miscounted
        // a frame's length would resync onto a body byte and produce nonsense.
        for (offset, record) in records.enumerated() {
            #expect(record.sequence == records[0].sequence + UInt64(offset))
            #expect(record.message.hasSuffix("|\(record.sequence)"))
        }
    }

    @Test("Truncates an over-long message rather than growing for it")
    func truncation() {
        var ring = FilaLogRing(capacityBytes: 64 * 1024)
        ring.append(level: .info, source: .app, message: String(repeating: "p", count: 10000))

        let message = ring.records(since: 0)[0].message
        #expect(message.utf8.count == FilaLogRing.maximumMessageByteCount)
    }

    @Test("A cut multi-byte scalar decodes rather than throwing the line away")
    func truncatedUTF8() {
        // The cut lands mid-scalar for at least one of these lengths. What is
        // *stored* is always at most the maximum; what decodes back can be a
        // byte or two longer, because a split scalar becomes U+FFFD — which is
        // the right outcome for a log line and is why the ceiling is measured
        // on the ring rather than on the string.
        for padding in 0 ... 3 {
            var ring = FilaLogRing(capacityBytes: 64 * 1024)
            ring.append(
                level: .info,
                source: .app,
                message: String(repeating: "a", count: FilaLogRing.maximumMessageByteCount - padding)
                    + String(repeating: "文", count: 4)
            )
            #expect(ring.usedBytes == FilaLogRing.headerByteCount + FilaLogRing.maximumMessageByteCount)
            let message = ring.records(since: 0)[0].message
            #expect(message.hasPrefix("a"))
            #expect(message.hasPrefix(String(repeating: "a", count: FilaLogRing.maximumMessageByteCount - padding)))
        }
    }

    @Test("Clearing keeps the sequence, so a poller is never handed a number twice")
    func clearing() {
        var ring = FilaLogRing(capacityBytes: 64 * 1024)
        for index in 1 ... 5 {
            ring.append(level: .info, source: .app, message: "\(index)")
        }
        ring.removeAll()
        #expect(ring.records(since: 0).isEmpty)

        ring.append(level: .info, source: .app, message: "after")
        #expect(ring.records(since: 0).map(\.sequence) == [6])
    }

    @Test("A capacity too small for one frame is raised to fit one")
    func minimumCapacity() {
        var ring = FilaLogRing(capacityBytes: 8)
        #expect(ring.capacityBytes >= FilaLogRing.headerByteCount + FilaLogRing.maximumMessageByteCount)
        ring.append(level: .info, source: .app, message: "still recorded")
        #expect(ring.records(since: 0).map(\.message) == ["still recorded"])
    }
}

/// `FilaLog` is one ring and one threshold for the whole process — which is
/// what a log is — so its tests share state and have to run one at a time.
@Suite("Log levels and writing", .serialized)
struct FilaLogTests {
    @Test("Order runs verbose → error, and the threshold filters from below")
    func ordering() {
        #expect(FilaLog.Level.verbose < FilaLog.Level.info)
        #expect(FilaLog.Level.info < FilaLog.Level.warning)
        #expect(FilaLog.Level.warning < FilaLog.Level.error)
        #expect(FilaLog.Level.allCases.count == 4)
        // The raw values are on the wire; changing one silently reinterprets
        // every line the other side sends.
        #expect(FilaLog.Level.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }

    @Test("Verbose is off by default and switches at runtime")
    func threshold() {
        let original = FilaLog.minimumLevel
        defer { FilaLog.minimumLevel = original }

        FilaLog.minimumLevel = .info
        #expect(!FilaLog.isEnabled(.verbose))
        #expect(FilaLog.isEnabled(.info))
        #expect(FilaLog.isEnabled(.error))

        FilaLog.minimumLevel = .verbose
        #expect(FilaLog.isEnabled(.verbose))

        FilaLog.minimumLevel = .error
        #expect(!FilaLog.isEnabled(.warning))
        #expect(FilaLog.isEnabled(.error))
    }

    @Test("A message below the threshold is never even built")
    func autoclosure() {
        let original = FilaLog.minimumLevel
        defer { FilaLog.minimumLevel = original }
        FilaLog.minimumLevel = .warning

        // The whole reason `verbose` takes an autoclosure: at verbose every
        // XPC round trip logs, and interpolating a path for a line nobody
        // keeps is the cost that made it not worth having.
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        FilaLog.verbose({ counter.value += 1; return "built" }())
        #expect(counter.value == 0)

        FilaLog.warning({ counter.value += 1; return "built" }())
        #expect(counter.value == 1)
    }

    @Test("Lines land in the shared ring and come back through the cursor")
    func endToEnd() {
        let original = FilaLog.minimumLevel
        defer { FilaLog.minimumLevel = original }
        FilaLog.start(.app, capacityBytes: 64 * 1024)
        FilaLog.clear()
        FilaLog.minimumLevel = .verbose

        FilaLog.info("hello \(1)")
        FilaLog.error("open /private/var errno 13")

        // The ring is process-wide and every other suite writes to it while
        // this one runs, so the subject is this test's own two lines.
        let mine: ([FilaLog.Record]) -> [FilaLog.Record] = { records in
            records.filter { $0.message == "hello 1" || $0.message == "open /private/var errno 13" }
        }
        let records = mine(FilaLog.snapshot().records)
        #expect(records.count == 2)
        #expect(records[0].message == "hello 1")
        #expect(records[0].source == .app)
        #expect(records[1].level == .error)

        let tail = mine(FilaLog.snapshot(since: records[0].sequence).records)
        #expect(tail.map(\.message) == ["open /private/var errno 13"])
    }

    @Test("A credential is scrubbed on the way in, so no copy is kept anywhere")
    func redactsOnWrite() {
        let original = FilaLog.minimumLevel
        defer { FilaLog.minimumLevel = original }
        FilaLog.start(.daemon, capacityBytes: 64 * 1024)
        FilaLog.clear()
        FilaLog.minimumLevel = .verbose

        FilaLog.info("PROPFIND https://bob:hunter2@dav.example.com/share")
        FilaLog.info("Authorization: Basic Ym9iOmh1bnRlcjI=")

        // Same shared ring as `endToEnd`: only the two lines written here.
        let messages = FilaLog.snapshot().records.map(\.message)
            .filter { $0.hasPrefix("PROPFIND ") || $0.hasPrefix("Authorization: ") }
        #expect(messages.count == 2)
        #expect(!messages.contains { $0.contains("hunter2") })
        #expect(!messages.contains { $0.contains("Ym9iOmh1bnRlcjI=") })
        // Still readable: the account and the host are what a diagnosis needs,
        // and a log scrubbed past legibility gets turned off.
        #expect(messages[0].contains("bob"))
        #expect(messages[0].contains("dav.example.com"))
    }

    @Test("Concurrent writers neither lose a line nor corrupt one")
    func concurrency() {
        let original = FilaLog.minimumLevel
        defer { FilaLog.minimumLevel = original }
        // Big enough that nothing is evicted, so a lost line is visible as a
        // missing one rather than as an eviction.
        FilaLog.start(.daemon, capacityBytes: 1 << 20)
        FilaLog.clear()
        FilaLog.minimumLevel = .verbose

        // The daemon writes from the control queue, the job queue and the
        // search queue at once; a torn frame here would be unreadable garbage
        // in the viewer with no way to trace it back.
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0 ..< 250 {
                FilaLog.verbose("worker \(worker) line \(index)")
            }
        }

        // Every other suite in this process logs through the same ring, and
        // the runner interleaves them, so the subject is this test's own lines
        // rather than everything the ring holds. Distinct messages and distinct
        // sequences across exactly 2000 of them is the torn-frame check: a
        // frame that lost or gained a byte cannot come back as one of these.
        let (all, dropped) = FilaLog.snapshot()
        let records = all.filter { $0.message.hasPrefix("worker ") }
        #expect(dropped == 0)
        #expect(records.count == 2000)
        #expect(Set(records.map(\.sequence)).count == 2000)
        #expect(Set(records.map(\.message)).count == 2000)
    }
}
