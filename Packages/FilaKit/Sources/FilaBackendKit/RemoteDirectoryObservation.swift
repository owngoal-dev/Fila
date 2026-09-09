import Foundation

/// The one owner of directory invalidation for a remote root.
///
/// A server this app talks to over SMB has no change notification the
/// selected library implements, so what a subscriber gets is a bounded poll:
/// one `stamp` of the directory every few seconds while someone is looking
/// at it, and a `Void` hint — "list it again" — only when the stamp moved.
/// A mutation the app ran itself is fed in through `invalidate` and hints
/// at once. Polling starts with a directory's first subscriber and stops
/// with its last; a paused observation polls nothing and hints every
/// subscriber once on resume, because anything may have happened meanwhile.
///
/// The stamp is opaque here: a modification time, a size, a hash of a
/// listing — whatever the backend can fetch cheaply and compare. A stamp
/// that cannot be fetched is not a change and not an error: a server that
/// went away shows up in the listing the next hint starts, with the real
/// failure attached.
@MainActor
public final class RemoteDirectoryObservation {
    /// How often an observed directory is asked for its stamp. A policy,
    /// not a latency promise.
    public nonisolated static let pollInterval: TimeInterval = 5

    public typealias Stamp = @Sendable () async throws -> String

    private struct Subscriber {
        let directory: String
        let continuation: AsyncThrowingStream<Void, Error>.Continuation
    }

    private struct Watch {
        var task: Task<Void, Never>
        var count: Int
        let stamp: Stamp
        var baseline: String?
        /// The watch is still taking its first stamp; a subscriber joining
        /// now is hinted by that baseline rather than separately.
        var baselinePending = false
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var watches: [String: Watch] = [:]
    private var paused = false
    private let interval: TimeInterval

    public nonisolated init(interval: TimeInterval = RemoteDirectoryObservation.pollInterval) {
        self.interval = interval
    }

    /// A new subscription to `directory`, with its initial hint on the way.
    /// `stamp` runs off the main actor and is what the poll compares.
    public func subscribe(_ directory: String, stamp: @escaping Stamp) -> AsyncThrowingStream<Void, Error> {
        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[token] = Subscriber(directory: directory, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.remove(token) }
        }
        if let watch = watches[directory] {
            watches[directory]?.count += 1
            if paused || !watch.baselinePending {
                continuation.yield(())
            }
        } else if paused {
            watches[directory] = Watch(task: Task {}, count: 1, stamp: stamp)
            continuation.yield(())
        } else {
            watches[directory] = Watch(task: Task {}, count: 1, stamp: stamp)
            // Two statements: `watch` writes the dictionary too, and an
            // assignment through the subscript holds its access open while
            // the right-hand side runs.
            let task = watch(directory)
            watches[directory]?.task = task
        }
        return stream
    }

    /// Hints every subscriber of one of `directories`, and restarts those
    /// watches from a fresh baseline so the next tick does not report the
    /// same change a second time.
    public func invalidate(_ directories: [String]) {
        for directory in Set(directories) where watches[directory] != nil {
            if paused {
                hint(directory)
            } else {
                watches[directory]?.task.cancel()
                let task = watch(directory)
                watches[directory]?.task = task
            }
        }
    }

    /// Every stream ends with `error`: what a lost connection does, so a
    /// subscriber retries with a fresh listing rather than waiting on a
    /// poll that can no longer reach the server.
    public func finishAll(throwing error: Error) {
        let ending = subscribers
        subscribers = [:]
        for watch in watches.values { watch.task.cancel() }
        watches = [:]
        for subscriber in ending.values {
            subscriber.continuation.finish(throwing: error)
        }
    }

    public func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        if paused {
            for watch in watches.values { watch.task.cancel() }
        } else {
            for directory in watches.keys {
                let task = watch(directory)
                watches[directory]?.task = task
            }
        }
    }

    public var subscriberCount: Int { subscribers.count }
    public var watchedDirectories: [String] { Array(watches.keys) }

    // MARK: - Polling

    private func remove(_ token: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: token) else { return }
        let directory = subscriber.directory
        guard var watch = watches[directory] else { return }
        watch.count -= 1
        if watch.count <= 0 {
            watch.task.cancel()
            watches[directory] = nil
        } else {
            watches[directory] = watch
        }
    }

    private func watch(_ directory: String) -> Task<Void, Never> {
        let interval = interval
        watches[directory]?.baselinePending = true
        return Task { [weak self] in
            guard await self?.rebaseline(directory) == true else { return }
            self?.watches[directory]?.baselinePending = false
            self?.hint(directory)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await tick(directory)
            }
        }
    }

    /// False when the watch was cancelled meanwhile: whatever replaced it
    /// hints on its own, and a stamp that outlived its watch installs
    /// nothing.
    private func rebaseline(_ directory: String) async -> Bool {
        guard let stamp = watches[directory]?.stamp else { return false }
        let now = try? await stamp()
        guard !Task.isCancelled else { return false }
        watches[directory]?.baseline = now
        return true
    }

    private func tick(_ directory: String) async {
        guard let stamp = watches[directory]?.stamp else { return }
        guard let now = try? await stamp(), !Task.isCancelled else { return }
        let previous = watches[directory]?.baseline
        watches[directory]?.baseline = now
        guard let previous, previous != now else { return }
        hint(directory)
    }

    private func hint(_ directory: String) {
        for subscriber in subscribers.values where subscriber.directory == directory {
            subscriber.continuation.yield(())
        }
    }
}
