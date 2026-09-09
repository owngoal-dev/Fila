import FilaBackendKit
@testable import FilaClient
import Foundation
import Testing

@Suite("Directory observation")
@MainActor
struct DirectoryObservationTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 1
        private var calls = 0
        func tick() { lock.lock(); value += 1; lock.unlock() }
        func read() -> Double { lock.lock(); defer { lock.unlock() }; calls += 1; return value }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// Counts a stream's hints from a task that is never cancelled —
    /// cancelling a consumer ends an `AsyncThrowingStream`, so a timed wait
    /// polls this instead of racing `next()`.
    private final class Hints: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var task: Task<Void, Never>?
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }

        init(_ stream: AsyncThrowingStream<Void, Error>) {
            task = Task { [weak self] in
                do {
                    for try await _ in stream {
                        guard let self else { return }
                        lock.withLock { value += 1 }
                    }
                } catch {}
            }
        }

        /// True once the count exceeds `after` within `seconds`.
        func hinted(after: Int, within seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if count > after { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return count > after
        }

        /// True when no hint arrives for `seconds`.
        func quiet(for seconds: Double) async -> Bool {
            let before = count
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return count == before
        }

        deinit { task?.cancel() }
    }

    @Test("A subscription yields once at start, then only when hinted")
    func initialAndHints() async throws {
        let observation = DirectoryObservation(interval: 3600)
        let clock = Clock()
        let hints = Hints(observation.subscribe("/tmp/a") { clock.read() })
        #expect(await hints.hinted(after: 0, within: 1))
        #expect(observation.subscriberCount == 1)

        // Neither a sibling nor a child hints the parent's screen...
        observation.invalidate(["/tmp/b"])
        observation.invalidate(["/tmp/a/child"])
        #expect(await hints.quiet(for: 0.1))
        // ...but the directory itself, or an ancestor, does — and three
        // hints in a row coalesce, never exceeding one per consumed turn.
        let before = hints.count
        observation.invalidate(["/tmp/a"])
        observation.invalidate(["/tmp"])
        observation.invalidate(["/"])
        #expect(await hints.hinted(after: before, within: 1))
        #expect(await hints.quiet(for: 0.1))
        #expect(hints.count <= before + 3)
    }

    @Test("Cancelling removes the subscriber; the last one releases the watch")
    func lifecycle() async throws {
        let observation = DirectoryObservation(interval: 3600)
        let clock = Clock()
        let one = Task {
            for try await _ in observation.subscribe("/tmp/a") { clock.read() } {}
        }
        let two = Task {
            for try await _ in observation.subscribe("/tmp/a") { clock.read() } {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(observation.subscriberCount == 2)
        #expect(observation.watchedDirectories == ["/tmp/a"])
        one.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(observation.subscriberCount == 1)
        #expect(observation.watchedDirectories == ["/tmp/a"])
        two.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(observation.subscriberCount == 0)
        #expect(observation.watchedDirectories.isEmpty)
    }

    @Test("Polling baselines at once, hints only when the modification time moves, and not while paused")
    func polling() async throws {
        let observation = DirectoryObservation(interval: 0.02)
        let clock = Clock()
        let hints = Hints(observation.subscribe("/tmp/a") { clock.read() })
        #expect(await hints.hinted(after: 0, within: 1))
        // Unchanged time: polls happen, hints do not.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(clock.reads >= 2)
        #expect(await hints.quiet(for: 0.1))
        var count = hints.count
        clock.tick()
        #expect(await hints.hinted(after: count, within: 1))
        // The change was reported once; the new time is the baseline now.
        #expect(await hints.quiet(for: 0.1))

        // An operation the app ran hints at once and re-baselines: the
        // tick after it must not report the same change again.
        count = hints.count
        clock.tick()
        observation.invalidate(["/tmp/a"])
        #expect(await hints.hinted(after: count, within: 1))
        #expect(await hints.quiet(for: 0.15))

        observation.setPaused(true)
        // A stat already in flight when the pause landed still completes —
        // the read happens off the main actor and cancellation cannot recall
        // it — so the count starts once that moment has passed.
        try await Task.sleep(nanoseconds: 50_000_000)
        let reads = clock.reads
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(clock.reads == reads, "no polling in the background")
        // Resuming hints once regardless, and polling restarts.
        count = hints.count
        observation.setPaused(false)
        #expect(await hints.hinted(after: count, within: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(clock.reads > reads)
    }

    @Test("The adapter's changes(in:) resolves the directory and reports a real modification")
    func adapterPolling() async throws {
        let scratch = LocalScratch()
        scratch.directory("watched")
        let observation = DirectoryObservation(interval: 0.02)
        let adapter = LocalFileServiceAdapter(access: LocalFileService(), rootPath: scratch.root, observation: observation)
        let hints = Hints(try await adapter.changes(in: try ServicePath("watched")))
        #expect(await hints.hinted(after: 0, within: 1))
        // The baseline is taken at subscription, so a change during the first
        // interval is seen. mtime resolution is a second on some filesystems:
        // set one that cannot equal the current time.
        var times = timeval(tv_sec: 1_600_000_000, tv_usec: 0)
        utimes(scratch.path("watched"), &times)
        #expect(await hints.hinted(after: 1, within: 2))
    }
}
