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
    nonisolated static let pollInterval: TimeInterval = 5

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

    /// A new subscription to `directory`, with its initial hint on the way.
    /// `stat` is what the poll compares; it runs off the main actor and
    /// reports the directory's modification time, which moves when an entry
    /// is added, removed or renamed.
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
        if let state = states[directory] {
            states[directory]?.count += 1
            // A watch still taking its baseline hints the whole directory
            // once it has one, and that covers this subscriber too; hinting
            // it now as well would list the same folder twice.
            if paused || !state.baselinePending {
                continuation.yield(())
            }
        } else if paused {
            states[directory] = WatchState(task: Task {}, count: 1, stat: stat)
            continuation.yield(())
        } else {
            states[directory] = WatchState(task: Task {}, count: 1, stat: stat)
            let task = watch(directory)
            states[directory]?.task = task
        }
        return stream
    }

    /// Hints every subscriber whose directory is one of `absolutePaths` or
    /// lies under one. What was touched is a directory an operation changed
    /// the contents of; a screen inside it is stale too. Each affected
    /// directory's watch starts over, so the hint follows a fresh baseline
    /// rather than the next tick reporting the same change a second time.
    func invalidate(_ absolutePaths: [String]) {
        let changed = absolutePaths.map(Self.canonical)
        var affected: Set<String> = []
        for subscriber in subscribers.values {
            let current = Self.canonical(subscriber.directory)
            guard changed.contains(where: { current == $0 || current.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
                continue
            }
            affected.insert(subscriber.directory)
        }
        for directory in affected {
            if paused {
                // Nothing polls while paused, and resuming re-baselines every
                // watch anyway; the hint itself must not wait for that.
                hint(directory)
            } else {
                states[directory]?.task.cancel()
                let task = watch(directory)
                states[directory]?.task = task
            }
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
            for directory in states.keys {
                let task = watch(directory)
                states[directory]?.task = task
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
        /// The modification time the next tick compares against. Always
        /// written by the running watch: a watch is cancelled before any
        /// hint that would make its baseline describe what that hint
        /// already reported, and a cancelled `stat` installs nothing.
        var baseline: Double?
        /// The watch has not taken its baseline yet, so the hint that follows
        /// it is still to come.
        var baselinePending = false
    }

    private var states: [String: WatchState] = [:]

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

    /// The one way into polling: a baseline `stat`, one hint to every
    /// subscriber of `directory`, then the ticks. The first subscriber, an
    /// operation's hint and resuming all start here, so the listing a hint
    /// starts is never older than the baseline the next tick compares it
    /// against — a change landing between the two is a difference, not the
    /// baseline. The hint follows a failed `stat` too; the listing is what
    /// shows the failure.
    private func watch(_ directory: String) -> Task<Void, Never> {
        let interval = interval
        states[directory]?.baselinePending = true
        return Task { [weak self] in
            guard await self?.rebaseline(directory) == true else { return }
            self?.states[directory]?.baselinePending = false
            self?.hint(directory)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await tick(directory)
            }
        }
    }

    /// False when the watch was cancelled meanwhile: whatever replaces it
    /// hints on its own, and a `stat` that outlived its watch installs
    /// nothing.
    private func rebaseline(_ directory: String) async -> Bool {
        guard let stat = states[directory]?.stat else { return false }
        let now = try? await stat()
        guard !Task.isCancelled else { return false }
        states[directory]?.baseline = now
        return true
    }

    private func tick(_ directory: String) async {
        guard let stat = states[directory]?.stat else { return }
        guard let now = try? await stat(), !Task.isCancelled else { return }
        let previous = states[directory]?.baseline
        states[directory]?.baseline = now
        guard let previous, previous != now else { return }
        hint(directory)
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
