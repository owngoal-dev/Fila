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
        let backends = BackendComposition.fileBackends
        let local = session.local
        func absolute(_ location: FileLocation) -> String? {
            location.backend == local.id ? local.absolutePath(location.path) : nil
        }
        // Every local directory the row should invalidate is known now; the
        // remote ones are hinted from the outcome once it is in.
        var affected: [String] = []
        if let target = absolute(destination) { affected.append(target) }
        for source in sources {
            if let parent = source.path.parent, let directory = absolute(FileLocation(backend: source.backend, path: parent)) {
                affected.append(directory)
            }
        }
        let names = sources.map { $0.path.name ?? "" }
        let destinationName = backends.first { $0.id == destination.backend }.map { backend in
            destination.path.isRoot ? backend.root.displayName : backend.root.displayName + "/" + destination.path.description
        } ?? destination.path.description
        let subtitle = Self.describe(names, destination: destinationName)
        let logSubject = Self.describeForLog(
            sources.map { "\($0.backend):\($0.path)" }, destination: "\(destination.backend):\(destination.path)"
        )
        let kind: Kind = mode == .move ? .move : .copy

        let box = OutcomeBox()
        let verdict: FilaFailure = await withCheckedContinuation { continuation in
            run(
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
                    sources, into: destination, mode: mode, policy: policy, backends: backends, session: self.session
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
        }
        return box.outcome ?? TransferOutcome(failure: verdict, affected: [], publishedFiles: 0)
    }

    /// Resolves both ends and runs the executor in a staging directory of
    /// its own, removed afterwards whatever happened inside it.
    private static func execute(
        _ sources: [FileLocation],
        into destination: FileLocation,
        mode: TransferMode,
        policy: PublishPolicy,
        backends: [any FileBackend],
        session: FileSession,
        progress: @escaping @Sendable (TransferProgressReport) -> Void
    ) async -> TransferOutcome {
        let sourceBackendIDs = Set(sources.map(\.backend))
        guard sourceBackendIDs.count == 1, let sourceID = sourceBackendIDs.first else {
            // One paste, one source backend: a selection is taken from one
            // screen. Anything else is a bug upstream, refused as such.
            return TransferOutcome(failure: TransferRefusal.nothingToTransfer, affected: [], publishedFiles: 0)
        }
        guard let sourceBackend = backends.first(where: { $0.id == sourceID }),
              let destinationBackend = backends.first(where: { $0.id == destination.backend })
        else {
            return TransferOutcome(failure: TransferRefusal.nothingToTransfer, affected: [], publishedFiles: 0)
        }
        do {
            let sourceService = try await sourceBackend.fileService()
            guard let destinationService = try await destinationBackend.fileService() as? any WritableFileService else {
                return TransferOutcome(failure: TransferRefusal.destinationNotWritable, affected: [], publishedFiles: 0)
            }
            let staging = try await session.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            let request = TransferRequest(
                source: TransferSource(backend: sourceID, service: sourceService, paths: sources.map(\.path)),
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
                lock.lock()
                let value = latest
                latest = nil
                scheduled = false
                lock.unlock()
                if let value { report(value) }
            }
        }
    }
}
