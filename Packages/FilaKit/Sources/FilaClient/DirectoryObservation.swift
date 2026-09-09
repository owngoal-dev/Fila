import FilaBackendKit
import FilaLog
import Foundation

/// The one owner of directory invalidation for a local root.
///
/// Subscribers ask about one directory each and receive `Void` hints —
/// "list it again" — never entries. Hints come from two sources: what an
/// operation reported touching, fed in by `invalidate`, and a bounded poll
/// of each observed directory's own modification time, which catches
/// changes made by other processes. Polling runs only while a directory
/// has a subscriber and the app is on screen, and yields only when the
/// directory's times actually moved, so an idle screen costs one `stat`
/// every few seconds and no listing.
@MainActor
final class DirectoryObservation {
    /// How often an observed directory is stat'ed. A policy, not a latency
    /// promise: an operation the app ran itself invalidates at once.
    static let pollInterval: TimeInterval = 5

    private struct Subscriber {
        let directory: String
        let continuation: AsyncThrowingStream<Void, Error>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var paused = false
    private let interval: TimeInterval

    init(interval: TimeInterval = DirectoryObservation.pollInterval) {
        self.interval = interval
    }

    /// A new subscription to `directory`, with its initial hint already
    /// buffered. `stat` is what the poll compares; it runs off the main
    /// actor and reports the directory's modification time, which moves
    /// when an entry is added, removed or renamed.
    func subscribe(
        _ directory: String,
        stat: @escaping @Sendable () async throws -> Double
    ) -> AsyncThrowingStream<Void, Error> {
        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[token] = Subscriber(directory: directory, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.remove(token) }
        }
        retain(directory, stat: stat)
        continuation.yield(())
        return stream
    }

    /// Hints every subscriber whose directory is one of `absolutePaths` or
    /// lies under one. What was touched is a directory an operation changed
    /// the contents of; a screen inside it is stale too. The poll's baseline
    /// for a hinted directory is dropped, so the next tick re-baselines
    /// rather than reporting the same change a second time.
    func invalidate(_ absolutePaths: [String]) {
        let changed = absolutePaths.map(Self.canonical)
        for subscriber in subscribers.values {
            let current = Self.canonical(subscriber.directory)
            guard changed.contains(where: { current == $0 || current.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
                continue
            }
            states[subscriber.directory]?.baseline = nil
            subscriber.continuation.yield(())
        }
    }

    /// Pausing stops every poll; resuming restarts them and hints every
    /// subscriber once, because anything may have happened meanwhile.
    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        if paused {
            for state in states.values { state.task.cancel() }
        } else {
            for (directory, state) in states {
                states[directory]?.task = poll(directory, stat: state.stat)
            }
            for subscriber in subscribers.values {
                subscriber.continuation.yield(())
            }
        }
    }

    var subscriberCount: Int { subscribers.count }
    var watchedDirectories: [String] { Array(states.keys) }

    // MARK: - Polling

    private struct WatchState {
        var task: Task<Void, Never>
        var count: Int
        let stat: @Sendable () async throws -> Double
        /// The modification time the next tick compares against. Nil until
        /// the first `stat` after subscribing, resuming or a hint.
        var baseline: Double?
    }

    private var states: [String: WatchState] = [:]

    private func retain(_ directory: String, stat: @escaping @Sendable () async throws -> Double) {
        if states[directory] != nil {
            states[directory]?.count += 1
            return
        }
        states[directory] = WatchState(task: paused ? Task {} : poll(directory, stat: stat), count: 1, stat: stat)
    }

    private func remove(_ token: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: token) else { return }
        guard var state = states[subscriber.directory] else { return }
        state.count -= 1
        if state.count == 0 {
            state.task.cancel()
            states[subscriber.directory] = nil
        } else {
            states[subscriber.directory] = state
        }
    }

    private func poll(
        _ directory: String,
        stat: @escaping @Sendable () async throws -> Double
    ) -> Task<Void, Never> {
        let interval = interval
        return Task { [weak self] in
            // Baseline now, not after the first sleep: a change during the
            // first interval must be seen against what the listing showed.
            if let now = try? await stat() {
                self?.states[directory]?.baseline = now
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let now = try? await stat(), let self, !Task.isCancelled else { continue }
                let previous = states[directory]?.baseline
                states[directory]?.baseline = now
                guard let previous, previous != now else { continue }
                hint(directory)
            }
        }
    }

    private func hint(_ directory: String) {
        for subscriber in subscribers.values where subscriber.directory == directory {
            subscriber.continuation.yield(())
        }
    }

    /// `/var` and `/private/var` are the same place; a comparison that
    /// does not know that misses every hint on a symlinked volume.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
