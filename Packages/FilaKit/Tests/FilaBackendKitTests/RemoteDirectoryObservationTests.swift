import FilaBackendKit
import Foundation
import Testing

/// A stamp source the tests move by hand.
private final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var stampReads = 0

    /// Read under the lock like every other field: the poll counts from its
    /// own task and the test compares from the main actor.
    var reads: Int { lock.withLock { stampReads } }

    func set(_ directory: String, _ value: String) {
        lock.withLock { values[directory] = value }
    }

    func stamp(_ directory: String) -> @Sendable () async throws -> String {
        { [self] in
            lock.withLock {
                stampReads += 1
                return values[directory] ?? "0"
            }
        }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var hints = 0
    private var endError: Error?

    var count: Int { lock.withLock { hints } }
    var ended: Error? { lock.withLock { endError } }

    func consume(_ stream: AsyncThrowingStream<Void, Error>) -> Task<Void, Never> {
        Task {
            do {
                for try await _ in stream {
                    lock.withLock { hints += 1 }
                }
            } catch {
                lock.withLock { endError = error }
            }
        }
    }

    /// Returns as soon as `expected` hints have arrived, and throws after
    /// `polls` turns of its own.
    ///
    /// The bound counts this loop's turns rather than wall clock, because
    /// wall clock is not a measure of whether the observation had a chance
    /// to run: this wait is not isolated, and the blocking PTY reads other
    /// suites perform can hold every thread of the cooperative pool for
    /// seconds at a time, so a `Date()` deadline expires while the loop it
    /// guards never ran — which is how all five of these tests failed at
    /// once in CI and nowhere else. A watch that hints nothing still ends
    /// the test, after the same number of chances on every machine.
    func wait(for expected: Int, polls: Int = 300) async throws {
        for _ in 0 ..< polls {
            if count >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard count >= expected else { throw Timeout() }
    }

    struct Timeout: Error {}
}

@Suite("Remote directory observation")
@MainActor
struct RemoteDirectoryObservationTests {
    /// True once the observation holds `subscribers`. A cancelled consumer
    /// ends its stream, and the termination handler hops back to the main
    /// actor to release the watch: that is a number of turns, not a length
    /// of time, for the reason `Collector.wait` documents.
    private func released(_ observation: RemoteDirectoryObservation, to subscribers: Int) async -> Bool {
        for _ in 0 ..< 300 {
            if observation.subscriberCount == subscribers { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return observation.subscriberCount == subscribers
    }

    @Test("Every subscriber gets the initial hint, and a moved stamp hints only that directory")
    func hintsPerDirectory() async throws {
        let stamps = Stamps()
        let observation = RemoteDirectoryObservation(interval: 0.05)
        let a = Collector(), b = Collector(), other = Collector()
        let aTask = a.consume(observation.subscribe("a", stamp: stamps.stamp("a")))
        let bTask = b.consume(observation.subscribe("a", stamp: stamps.stamp("a")))
        let otherTask = other.consume(observation.subscribe("other", stamp: stamps.stamp("other")))
        try await a.wait(for: 1)
        try await b.wait(for: 1)
        try await other.wait(for: 1)
        #expect(observation.subscriberCount == 3)
        #expect(observation.watchedDirectories.sorted() == ["a", "other"])
        stamps.set("a", "1")
        try await a.wait(for: 2)
        try await b.wait(for: 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(other.count == 1, "a stamp that did not move hints nothing")
        #expect(a.count == 2, "one change is one hint, not one per tick")
        aTask.cancel()
        bTask.cancel()
        otherTask.cancel()
        #expect(await released(observation, to: 0))
        #expect(observation.watchedDirectories.isEmpty, "the last subscriber releases the watch")
    }

    @Test("Cancelling one subscriber leaves the other polling")
    func cancelOne() async throws {
        let stamps = Stamps()
        let observation = RemoteDirectoryObservation(interval: 0.05)
        let a = Collector(), b = Collector()
        let aTask = a.consume(observation.subscribe("d", stamp: stamps.stamp("d")))
        let bTask = b.consume(observation.subscribe("d", stamp: stamps.stamp("d")))
        try await a.wait(for: 1)
        try await b.wait(for: 1)
        aTask.cancel()
        #expect(await released(observation, to: 1))
        #expect(observation.watchedDirectories == ["d"])
        stamps.set("d", "1")
        try await b.wait(for: 2)
        bTask.cancel()
    }

    @Test("An invalidation hints at once and restarts from a fresh baseline")
    func invalidate() async throws {
        let stamps = Stamps()
        let observation = RemoteDirectoryObservation(interval: 0.05)
        let a = Collector()
        let task = a.consume(observation.subscribe("d", stamp: stamps.stamp("d")))
        try await a.wait(for: 1)
        stamps.set("d", "1")
        observation.invalidate(["d", "unwatched"])
        try await a.wait(for: 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(a.count == 2, "the stamp that moved with the invalidation is not reported again by the next tick")
        task.cancel()
    }

    @Test("Paused observation polls nothing and hints everyone once on resume")
    func pause() async throws {
        let stamps = Stamps()
        let observation = RemoteDirectoryObservation(interval: 0.05)
        let a = Collector()
        let task = a.consume(observation.subscribe("d", stamp: stamps.stamp("d")))
        try await a.wait(for: 1)
        observation.setPaused(true)
        let readsWhilePaused = stamps.reads
        stamps.set("d", "1")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(stamps.reads == readsWhilePaused)
        #expect(a.count == 1)
        let late = Collector()
        let lateTask = late.consume(observation.subscribe("d", stamp: stamps.stamp("d")))
        try await late.wait(for: 1)
        observation.setPaused(false)
        try await a.wait(for: 2)
        try await late.wait(for: 2)
        task.cancel()
        lateTask.cancel()
    }

    @Test("A lost session ends every stream with its error")
    func finishAll() async throws {
        struct Lost: Error {}
        let stamps = Stamps()
        let observation = RemoteDirectoryObservation(interval: 0.05)
        let a = Collector(), b = Collector()
        let aTask = a.consume(observation.subscribe("x", stamp: stamps.stamp("x")))
        let bTask = b.consume(observation.subscribe("y", stamp: stamps.stamp("y")))
        try await a.wait(for: 1)
        try await b.wait(for: 1)
        observation.finishAll(throwing: Lost())
        await aTask.value
        await bTask.value
        #expect(a.ended is Lost)
        #expect(b.ended is Lost)
        #expect(observation.subscriberCount == 0)
        #expect(observation.watchedDirectories.isEmpty)
    }
}
