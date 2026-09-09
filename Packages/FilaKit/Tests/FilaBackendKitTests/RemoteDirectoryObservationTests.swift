import FilaBackendKit
import Foundation
import Testing

/// A stamp source the tests move by hand.
private final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var reads = 0

    func set(_ directory: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[directory] = value
    }

    func stamp(_ directory: String) -> @Sendable () async throws -> String {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return values[directory] ?? "0"
        }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var hints = 0
    private(set) var ended: Error?

    var count: Int { lock.lock(); defer { lock.unlock() }; return hints }

    func consume(_ stream: AsyncThrowingStream<Void, Error>) -> Task<Void, Never> {
        Task {
            do {
                for try await _ in stream {
                    lock.lock(); hints += 1; lock.unlock()
                }
            } catch {
                lock.lock(); ended = error; lock.unlock()
            }
        }
    }

    func wait(for expected: Int, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while count < expected {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    struct Timeout: Error {}
}

@Suite("Remote directory observation")
@MainActor
struct RemoteDirectoryObservationTests {
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
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(observation.subscriberCount == 0)
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
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(observation.subscriberCount == 1)
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
