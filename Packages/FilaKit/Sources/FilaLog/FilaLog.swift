import Darwin
import Foundation

#if canImport(os)
import os
#endif

/// What a log line is allowed to say, and what it may never say.
///
/// **The privacy rule, in one sentence: a line carries names, numbers and
/// paths — never bytes, never a value, never a credential.**
///
/// Paths are the point. This app browses the user's whole filesystem and the
/// answer to "it wouldn't delete" is a path and an `errno`, so
/// `/var/mobile/Library/Preferences/com.apple.springboard.plist` belongs in a
/// line and is interpolated `.public` into the unified log deliberately — a
/// redacted log is a log nobody can debug from.
///
/// What must never appear, because the buffer is shareable in one tap:
///
/// - **File contents.** Not a preview, not a first line, not a hex head. The
///   whole architecture rests on bytes never entering the daemon; a log line
///   is not the exception. Nothing in this module takes `Data`, and no call
///   site formats a buffer into a message.
/// - **Extended-attribute *values*.** The name and the byte count, never the
///   bytes: an xattr is a file in disguise.
/// - **Credentials.** The WebDAV server's Basic-auth password, the
///   `Authorization` header that carries it, and any `user:pass@` in a URL.
///   Log the username, the client address and the status code; that is the
///   whole of what a diagnosis needs.
/// - **A spawned command's arguments.** Execution is no longer forbidden in
///   this project, and an argument vector is the single most reliable place a
///   password ends up — `--password`, `-p`, a URL with userinfo in it. Log
///   what is being run and as whom; the argv is not a diagnosis, it is a leak
///   waiting for someone to tap Share.
///
/// Two things enforce that rather than merely asking for it. `redacting(_:)`
/// runs over **every** message on its way into the ring *and* into `os_log`,
/// so the shapes a credential actually arrives in — an `Authorization` header,
/// a `Basic`/`Bearer` token, `password=…`, a `--password` flag and its value,
/// `scheme://user:pass@host` — are replaced before anything keeps them. And a
/// message is truncated to `FilaLogRing.maximumMessageByteCount`, so whatever
/// the scrubber does not know about leaks at most one line, once, rather than
/// a file.
///
/// Neither makes it safe to log a secret on purpose. They make the accident
/// survivable, which is what a rule enforced only by good intentions is not.
///
/// ## Where the lines go
///
/// Two places, both cheap. `os_log` under subsystem `wiki.qaq.fila`, which is
/// where a jailbreak user already knows to look
/// (`log stream --predicate 'subsystem == "wiki.qaq.fila"'`), and an in-memory
/// ring the log screen reads back — because the unified log's relay drops
/// lines while a device is busy, and the daemon is exactly the process whose
/// lines get dropped.
///
/// The ring is a fixed byte allocation and never grows. `filad` lives under
/// launchd's 6 MB jetsam cap, so an unbounded array or an ever-growing file is
/// not an option: see `FilaLogRing`.
public enum FilaLog {
    /// Which process a line came from. Stamped into every record, so the app's
    /// viewer can interleave both sides on one timeline — the request and the
    /// daemon's handling of it, in order, which is the whole diagnostic value.
    public enum Source: UInt8, Sendable, Hashable {
        case app = 0
        case daemon = 1

        public var name: String {
            switch self {
            case .app: return "Fila"
            case .daemon: return "filad"
            }
        }
    }

    public enum Level: UInt8, Sendable, Hashable, Comparable, CaseIterable {
        /// Every XPC round trip, every path, every decision. Off by default:
        /// a copy at verbose writes thousands of lines a second.
        case verbose = 0
        /// Lifecycle — what launched, what connected, what job started.
        case info = 1
        /// A refusal the user will notice: the guard, a peer rejected.
        case warning = 2
        /// A syscall that failed, with its `errno`.
        case error = 3

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        /// Four characters, so the exported text lines up in a column.
        public var tag: String {
            switch self {
            case .verbose: return "VERB"
            case .info: return "INFO"
            case .warning: return "WARN"
            case .error: return "FAIL"
            }
        }
    }

    /// The whole of what a line is. No category: the text filter in the viewer
    /// does that job, and a category enum is one more thing to keep in step.
    public struct Record: Sendable, Hashable {
        /// Monotonic per process, starting at 1. The viewer polls with the
        /// last one it saw, so this is also the cursor.
        public var sequence: UInt64
        /// Seconds since 1970, from `gettimeofday`.
        public var time: Double
        public var level: Level
        public var source: Source
        public var message: String

        public init(sequence: UInt64, time: Double, level: Level, source: Source, message: String) {
            self.sequence = sequence
            self.time = time
            self.level = level
            self.source = source
            self.message = message
        }
    }

    /// Bytes the daemon's ring costs. See `FilaLogRing` for why this is the
    /// number that matters.
    public static let daemonCapacityBytes = 128 * 1_024

    /// The app has no jetsam cap worth worrying about and a longer history is
    /// worth more there, since it is the side the user is looking at.
    public static let appCapacityBytes = 512 * 1_024

    private static let state = State()

    /// Names this process and sizes its ring. Call once, first thing:
    /// `FilaLog.start(.app)` from the app delegate, `FilaLog.start(.daemon)`
    /// from `filad`'s `main`. Lines written before it are kept — they just
    /// carry the default source.
    public static func start(_ source: Source, capacityBytes: Int? = nil) {
        state.start(
            source,
            capacityBytes: capacityBytes ?? (source == .daemon ? daemonCapacityBytes : appCapacityBytes)
        )
    }

    /// Lines below this are dropped before they are formatted. `.info` by
    /// default — verbose is off until someone turns it on from the log screen,
    /// which is a live change and not a relaunch.
    public static var minimumLevel: Level {
        get { state.minimumLevel }
        set { state.minimumLevel = newValue }
    }

    /// True when a line at `level` would be kept. For a caller that would pay
    /// real cost to build the message; the `@autoclosure` below covers the
    /// ordinary case.
    public static func isEnabled(_ level: Level) -> Bool {
        level >= state.minimumLevel
    }

    public static func verbose(_ message: @autoclosure () -> String) { write(.verbose, message) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public static func warning(_ message: @autoclosure () -> String) { write(.warning, message) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message) }

    public static func log(_ level: Level, _ message: @autoclosure () -> String) { write(level, message) }

    /// Every record in the ring newer than `sequence`, oldest first, and how
    /// many have been evicted since this process started. A viewer that sees
    /// `dropped` grow between polls knows it missed lines rather than guessing.
    public static func snapshot(since sequence: UInt64 = 0) -> (records: [Record], dropped: UInt64) {
        state.snapshot(since: sequence)
    }

    public static func clear() {
        state.clear()
    }

    private static func write(_ level: Level, _ message: () -> String) {
        guard isEnabled(level) else { return }
        state.append(level, message())
    }

    /// The mutable half, so `FilaLog` itself can stay an enum of static calls.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var ring = FilaLogRing(capacityBytes: FilaLog.daemonCapacityBytes)
        private var source = Source.app
        private var level = Level.info

        #if canImport(os)
        /// One logger per process, its category naming the side. Replaced by
        /// `start`; until then a line still reaches `log stream`, under the
        /// default category rather than under none.
        private var logger = Logger(subsystem: "wiki.qaq.fila", category: "app")
        #endif

        var minimumLevel: Level {
            get { lock.lock(); defer { lock.unlock() }; return level }
            set { lock.lock(); level = newValue; lock.unlock() }
        }

        func start(_ source: Source, capacityBytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            self.source = source
            if capacityBytes != ring.capacityBytes {
                ring = FilaLogRing(capacityBytes: capacityBytes)
            }
            #if canImport(os)
            logger = Logger(subsystem: "wiki.qaq.fila", category: source == .daemon ? "daemon" : "app")
            #endif
        }

        func append(_ level: Level, _ rawMessage: String) {
            // Before the ring and before `os_log`, so there is no copy of the
            // original anywhere. See the privacy rule at the top of this file.
            let message = FilaLog.redacting(rawMessage)
            lock.lock()
            #if canImport(os)
            let logger = logger
            #endif
            ring.append(level: level, source: source, message: message)
            lock.unlock()

            #if canImport(os)
            // `.public` on purpose, and only ever safe because of the privacy
            // rule at the top of this file: nothing here carries content.
            logger.log(level: level.osLogType, "\(message, privacy: .public)")
            #endif
        }

        func snapshot(since sequence: UInt64) -> (records: [Record], dropped: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (ring.records(since: sequence), ring.droppedCount)
        }

        func clear() {
            lock.lock()
            ring.removeAll()
            lock.unlock()
        }
    }
}

#if canImport(os)
private extension FilaLog.Level {
    var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}
#endif

/// A fixed-size byte ring of log records. **This allocation is the whole of
/// what logging costs the daemon**, and it is why the daemon logs into memory
/// rather than into an array or a file.
///
/// `filad` runs under launchd's 6 MB jetsam cap. An array of records grows
/// with the flood it is recording — a verbose copy of a large tree writes
/// thousands of lines a second — and a file the daemon appends to grows on the
/// user's data volume forever and needs rotation, locking and a path that
/// works on four bootstrap layouts. A ring of `capacityBytes` needs none of
/// that: it is allocated once, at `start`, and the process's log footprint is
/// that number from then on regardless of how much is logged.
///
/// The daemon's number is `FilaLog.daemonCapacityBytes` — 128 KiB, about 2% of
/// the jetsam budget, roughly a thousand lines of history.
///
/// Frames are laid out little-endian and read back byte at a time, so a frame
/// that straddles the wrap needs no special case and nothing here is unaligned
/// or unsafe:
///
///     u32 message byte count
///     u64 sequence
///     f64 time
///     u8  level
///     u8  source
///     …   message bytes, UTF-8
public struct FilaLogRing {
    /// A message longer than this is cut. It bounds a frame, which is what
    /// makes the ceiling a ceiling — and it bounds a privacy mistake to one
    /// line rather than one file.
    public static let maximumMessageByteCount = 1_024

    static let headerByteCount = 4 + 8 + 8 + 1 + 1

    public let capacityBytes: Int
    private var storage: [UInt8]
    /// Offset of the oldest byte in use.
    private var start = 0
    private var used = 0
    private var sequence: UInt64 = 0
    /// Records evicted since this ring was made. Monotonic, so a viewer can
    /// tell "nothing was lost" from "I missed some".
    public private(set) var droppedCount: UInt64 = 0

    public init(capacityBytes: Int) {
        // A ring that cannot hold one worst-case frame would evict the record
        // it is writing, which is a silent no-op rather than a ring.
        self.capacityBytes = max(capacityBytes, Self.headerByteCount + Self.maximumMessageByteCount)
        storage = [UInt8](repeating: 0, count: self.capacityBytes)
    }

    /// Bytes of the allocation currently holding records. Never above
    /// `capacityBytes` — that is the invariant the jetsam cap rests on.
    public var usedBytes: Int { used }

    public mutating func append(level: FilaLog.Level, source: FilaLog.Source, message: String) {
        // Cut on a byte boundary rather than a Character one: the tail of a
        // split scalar decodes as U+FFFD, which is a fine thing for a log line
        // to say and far less code than finding the boundary.
        var payload = Array(message.utf8)
        if payload.count > Self.maximumMessageByteCount {
            payload = Array(payload[0 ..< Self.maximumMessageByteCount])
        }

        // `init` sized the ring so one worst-case frame always fits, so this
        // always terminates with room — the `used > 0` is belt and braces
        // against a future capacity that stops honouring that.
        let frameSize = Self.headerByteCount + payload.count
        while used > 0, used + frameSize > capacityBytes { evictOldest() }
        guard used + frameSize <= capacityBytes else { return }

        sequence &+= 1
        write(uint32: UInt32(payload.count))
        write(uint64: sequence)
        write(uint64: FilaLogRing.now().bitPattern)
        write(byte: level.rawValue)
        write(byte: source.rawValue)
        for byte in payload { write(byte: byte) }
    }

    /// Every record newer than `sequence`, oldest first.
    public func records(since sequence: UInt64) -> [FilaLog.Record] {
        var records: [FilaLog.Record] = []
        var offset = 0
        while offset < used {
            let length = Int(uint32(at: offset))
            let recordSequence = uint64(at: offset + 4)
            if recordSequence > sequence {
                var bytes = [UInt8](repeating: 0, count: length)
                for index in 0 ..< length { bytes[index] = byte(at: offset + Self.headerByteCount + index) }
                records.append(FilaLog.Record(
                    sequence: recordSequence,
                    time: Double(bitPattern: uint64(at: offset + 12)),
                    level: FilaLog.Level(rawValue: byte(at: offset + 20)) ?? .info,
                    source: FilaLog.Source(rawValue: byte(at: offset + 21)) ?? .app,
                    message: String(decoding: bytes, as: UTF8.self)
                ))
            }
            offset += Self.headerByteCount + length
        }
        return records
    }

    /// Drops every record. The sequence keeps counting: a viewer polling with
    /// a cursor must never be handed a number it has already seen.
    public mutating func removeAll() {
        start = 0
        used = 0
    }

    private mutating func evictOldest() {
        guard used > 0 else { return }
        let frameSize = Self.headerByteCount + Int(uint32(at: 0))
        start = (start + frameSize) % capacityBytes
        used -= frameSize
        droppedCount &+= 1
    }

    // MARK: - Bytes

    /// `offset` is measured from the oldest byte, not from the storage's own
    /// zero — every reader and writer here works in that space, so the wrap is
    /// one `%` in one place.
    private func byte(at offset: Int) -> UInt8 {
        storage[(start + offset) % capacityBytes]
    }

    private func uint32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0 ..< 4 { value |= UInt32(byte(at: offset + index)) << (8 * index) }
        return value
    }

    private func uint64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 { value |= UInt64(byte(at: offset + index)) << (8 * index) }
        return value
    }

    private mutating func write(byte: UInt8) {
        storage[(start + used) % capacityBytes] = byte
        used += 1
    }

    private mutating func write(uint32 value: UInt32) {
        for index in 0 ..< 4 { write(byte: UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    private mutating func write(uint64 value: UInt64) {
        for index in 0 ..< 8 { write(byte: UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    /// `gettimeofday`, not `Date()`: this runs inside a process that is trying
    /// not to drag anything it does not need, and the viewer is the side that
    /// formats.
    static func now() -> Double {
        var value = timeval()
        gettimeofday(&value, nil)
        return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
