import FilaBackendKit
import FilaClient
import FilaLog
import FilaProtocol
import Foundation

/// A copy or move between backends: the one `FileTransfer` run, as an
/// operation like a daemon job — the same row, progress bar, stop button
/// and receipt. Local-to-local never comes here: that is the native job.
///
/// The centre owns the task, the row and the verdict; `FileTransfer` owns
/// the staging directory's contents and the evidence of what it published.
/// The outcome goes back to the caller whole, because a transfer's failure
/// is a sentence the caller composes — which names were skipped, retained
/// or left uncertain — and the row keeps only the verdict.
extension OperationCenter {
    /// Runs the transfer and returns its outcome once the row has settled.
    /// Feedback is the caller's: the row announces nothing.
    func transfer(
        _ sources: [FileLocation],
        into destination: FileLocation,
        mode: TransferMode,
        policy: PublishPolicy
    ) async -> TransferOutcome {
        let local = session.local
        if sources.allSatisfy({ $0.backend == local.id }) {
            return await transfer(localPaths: sources.map { local.absolutePath($0.path) }, into: destination, mode: mode, policy: policy)
        }
        let backends = BackendComposition.fileBackends
        return await run(
            names: sources.map { $0.path.name ?? "" },
            logged: sources.map { "\($0.backend):\($0.path)" },
            sourceDirectories: [],
            into: destination,
            mode: mode,
            policy: policy
        ) {
            try await Self.source(for: sources, in: backends)
        }
    }

    /// Local files to `destination` — a selection, or the app workspace
    /// holding what another app dropped — read through the local layer
    /// rooted at the folder they share. Not as the local backend's
    /// locations: a sandboxed local root (Documents) contains neither the
    /// workspace nor the Inbox. Same access, same guard.
    func transfer(
        localPaths: [String],
        into destination: FileLocation,
        mode: TransferMode,
        policy: PublishPolicy
    ) async -> TransferOutcome {
        let parents = Set(localPaths.map { ($0 as NSString).deletingLastPathComponent })
        let root = Self.commonDirectory(of: parents)
        let prefix = root == "/" ? 0 : root.count
        let paths = localPaths.compactMap { try? ServicePath(String($0.dropFirst(prefix))) }
        guard !paths.isEmpty, paths.count == localPaths.count else {
            return TransferOutcome(failure: TransferRefusal.nothingToTransfer, affected: [], publishedFiles: 0)
        }
        let service = session.local.service(rootedAt: root)
        return await run(
            names: localPaths.map { ($0 as NSString).lastPathComponent },
            logged: localPaths,
            sourceDirectories: Array(parents),
            into: destination,
            mode: mode,
            policy: policy
        ) {
            // Its own identity: these paths are relative to `root`, not to
            // the local backend's, so the outcome's hints about the source
            // must not reach the backend. The parents are invalidated above.
            TransferSource(backend: BackendID("local-paths"), service: service, paths: paths)
        }
    }

    /// The deepest directory containing every one of `directories`.
    private static func commonDirectory(of directories: Set<String>) -> String {
        let split = directories.map { $0.split(separator: "/") }
        guard var common = split.first else { return "/" }
        for components in split.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        return "/" + common.joined(separator: "/")
    }

    /// The row, the progress and the verdict, whatever the source is.
    private func run(
        names: [String],
        logged: [String],
        sourceDirectories: [String],
        into destination: FileLocation,
        mode: TransferMode,
        policy: PublishPolicy,
        source: @escaping @Sendable () async throws -> TransferSource
    ) async -> TransferOutcome {
        let backends = BackendComposition.fileBackends
        let local = session.local
        // Every local directory the row should invalidate is known now; the
        // remote ones are hinted from the outcome once it is in.
        var affected = sourceDirectories
        if destination.backend == local.id { affected.append(local.absolutePath(destination.path)) }
        let destinationName = backends.first { $0.id == destination.backend }.map { backend in
            destination.path.isRoot ? backend.root.displayName : backend.root.displayName + "/" + destination.path.description
        } ?? destination.path.description
        let subtitle = Self.describe(names, destination: destinationName)
        let logSubject = Self.describeForLog(logged, destination: "\(destination.backend):\(destination.path)")
        let kind: Kind = mode == .move ? .move : .copy

        let box = OutcomeBox()
        // A caller that is cancelled — a progress card's Cancel — stops the
        // row the way its own stop button would.
        let verdict: FilaFailure = await withTaskCancellationHandler { await withCheckedContinuation { continuation in
            box.operation = run(
                kind: kind,
                title: kind.runningTitle,
                subtitle: subtitle,
                logSubject: logSubject,
                affected: Array(Set(affected)),
                feedback: .silent,
                whenFinished: { continuation.resume(returning: $0) }
            ) { report in
                let relay = ProgressRelay(report)
                let outcome = await Self.execute(
                    source, into: destination, mode: mode, policy: policy, backends: backends, session: self.session
                ) { progress in
                    relay.post(JobProgress(
                        bytesDone: progress.bytesDone,
                        bytesTotal: progress.planning ? 0 : progress.bytesTotal,
                        itemsDone: progress.itemsDone,
                        itemsTotal: progress.itemsTotal,
                        currentPath: progress.currentName
                    ))
                }
                box.outcome = outcome
                // Both ends list again, whatever happened: a partial
                // transfer changed them too.
                for location in outcome.affected {
                    backends.first { $0.id == location.backend }?.invalidate([location.path])
                }
                if let failure = outcome.failure {
                    if failure is CancellationError { throw CancellationError() }
                    if let known = failure as? FilaFailure { throw known }
                    throw FilaFailure(code: .operationFailed, path: Self.failedPath(failure))
                }
            }
        } } onCancel: {
            Task { @MainActor [weak self] in
                if let operation = self?.operations.first(where: { $0.id == box.operation }) { self?.cancel(operation) }
            }
        }
        return box.outcome ?? TransferOutcome(failure: verdict, affected: [], publishedFiles: 0)
    }

    /// The source of a transfer between registered backends.
    private static func source(for sources: [FileLocation], in backends: [any FileBackend]) async throws -> TransferSource {
        let sourceBackendIDs = Set(sources.map(\.backend))
        // One paste, one source backend: a selection is taken from one
        // screen. Anything else is a bug upstream, refused as such.
        guard sourceBackendIDs.count == 1, let sourceID = sourceBackendIDs.first,
              let backend = backends.first(where: { $0.id == sourceID })
        else { throw TransferRefusal.nothingToTransfer }
        return try await TransferSource(backend: sourceID, service: backend.fileService(), paths: sources.map(\.path))
    }

    /// Resolves both ends and runs the executor in a staging directory of
    /// its own, removed afterwards whatever happened inside it.
    private static func execute(
        _ makeSource: () async throws -> TransferSource,
        into destination: FileLocation,
        mode: TransferMode,
        policy: PublishPolicy,
        backends: [any FileBackend],
        session: FileSession,
        progress: @escaping @Sendable (TransferProgressReport) -> Void
    ) async -> TransferOutcome {
        guard let destinationBackend = backends.first(where: { $0.id == destination.backend }) else {
            return TransferOutcome(failure: TransferRefusal.nothingToTransfer, affected: [], publishedFiles: 0)
        }
        do {
            let source = try await makeSource()
            guard let destinationService = try await destinationBackend.fileService() as? any WritableFileService else {
                return TransferOutcome(failure: TransferRefusal.destinationNotWritable, affected: [], publishedFiles: 0)
            }
            let staging = try await session.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            let request = TransferRequest(
                source: source,
                destination: TransferDestination(backend: destination.backend, service: destinationService, directory: destination.path),
                mode: mode,
                policy: policy
            )
            return await FileTransfer.run(request, staging: staging, progress: progress)
        } catch {
            return TransferOutcome(failure: error, affected: [], publishedFiles: 0)
        }
    }

    /// The path a row's verdict names, when the failure names one.
    private static func failedPath(_ failure: Error) -> String? {
        switch failure {
        case let refusal as TransferRefusal:
            switch refusal {
            case let .sameLocation(path), let .insideSource(path), let .sizeMismatch(path, _, _): return path.description
            default: return nil
            }
        case let write as WriteFailure:
            switch write {
            case let .alreadyExists(path), let .notFound(path), let .notEmpty(path), let .publicationUnknown(path):
                return path.description
            }
        case let shortfall as TransferShortfall:
            return (shortfall.uncertain.first ?? shortfall.retained.first ?? shortfall.skipped.first)?.description
        default:
            return nil
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        var operation: UUID?
        var outcome: TransferOutcome?
    }

    /// Progress from the backends' threads onto the main actor, newest
    /// only: one main-actor hop in flight at a time, carrying whatever the
    /// latest report was when it ran. A megabyte-per-chunk transfer would
    /// otherwise queue thousands of hops with no promise of their order,
    /// and a bar that steps backwards is a bar nobody trusts.
    private final class ProgressRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let report: @MainActor (JobProgress) -> Void
        private var latest: JobProgress?
        private var scheduled = false

        init(_ report: @escaping @MainActor (JobProgress) -> Void) {
            self.report = report
        }

        func post(_ progress: JobProgress) {
            lock.lock()
            latest = progress
            let schedule = !scheduled
            scheduled = true
            lock.unlock()
            guard schedule else { return }
            Task { @MainActor [self] in
                if let value = take() { report(value) }
            }
        }

        /// The pending value, taken under the lock from a synchronous frame:
        /// a lock held across an await is a hang, and the compiler refuses
        /// `lock()` in an async context for that reason.
        private func take() -> JobProgress? {
            lock.lock()
            defer { lock.unlock() }
            let value = latest
            latest = nil
            scheduled = false
            return value
        }
    }
}
