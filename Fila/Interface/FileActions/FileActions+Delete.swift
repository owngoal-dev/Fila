import AlertController
import FilaProtocol
import UIKit

extension FileActions {
    func delete(_ paths: [String], permanently: Bool = false) {
        guard !paths.isEmpty else { return }
        // Inside the trash every delete is final, whichever control asked:
        // trashing a trashed item would only move it within the trash.
        if AppPreferences.shared.usesTrash, !permanently, !paths.allSatisfy(Self.isInTrash) {
            startDelete(paths, useTrash: true)
        } else {
            guard let presenter = activePresenter else { return }
            PermanentDeleteConfirmation.present(
                from: presenter,
                title: String(localized: "Delete Permanently?"),
                message: String(localized: "\(paths.count) items will be deleted and cannot be recovered.")
            ) { self.startDelete(paths) }
        }
    }

    func promptOverriddenDelete(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        guard let presenter = activePresenter else { return }
        PermanentDeleteConfirmation.present(
            from: presenter,
            title: String(localized: "Override Protection?"),
            message: String(localized: "The device needs this item to start up. Deleting it cannot be undone, and the device may need to be restored."),
            confirmTitle: String(localized: "Delete Anyway")
        ) { self.startDelete(paths, overrideGuard: true) }
    }

    private func startDelete(_ paths: [String], useTrash: Bool = false, overrideGuard: Bool = false) {
        presenter?.setEditing(false, animated: true)
        Task {
            let kind: OperationCenter.Kind = useTrash ? .trash : .delete
            let description = OperationCenter.describe(paths, destination: nil)
            let progress = AlertProgressIndicatorViewController(title: kind.runningTitle, message: description)
            let reveal = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000))
                } catch { return }
                guard !Task.isCancelled, let presenter = activePresenter else { return }
                // Cross-volume trash can take minutes. Its existing task page
                // provides progress and cancellation without trapping the user
                // behind the non-interactive progress card used for deletion.
                if useTrash {
                    TransfersViewController.presentAsSheet()
                    return
                }
                // Wait for presentation to finish before a job that completes
                // during the animation asks this same alert to dismiss.
                await withCheckedContinuation { continuation in
                    presenter.present(progress, animated: true) { continuation.resume() }
                }
            }
            let result: Result<FilaFailure, Error>
            do {
                let outcome = try await withSourceLocked {
                    if useTrash {
                        return try await session.operations.trash(paths, feedback: .successOnly)
                    }
                    return try await session.operations.awaitJob(
                        JobRequest(kind: .delete, sources: paths, useTrash: useTrash, overrideGuard: overrideGuard),
                        kind: kind,
                        subtitle: description,
                        feedback: .successOnly
                    )
                }
                result = .success(outcome)
            } catch { result = .failure(error) }

            reveal.cancel()
            await reveal.value
            let complete = {
                switch result {
                case let .success(outcome):
                    if outcome.code == .success {
                        self.didRemove()
                    } else if outcome.code != .cancelled {
                        self.reportDeleteFailure(outcome, paths: paths, useTrash: useTrash)
                    }
                case let .failure(failure as FilaFailure):
                    self.reportDeleteFailure(failure, paths: paths, useTrash: useTrash)
                case let .failure(error): self.report(error)
                }
            }
            // Background work may outlive this screen or a newer sheet. Only
            // close the alert this operation presented, then report its result.
            if progress.presentingViewController?.presentedViewController === progress,
               progress.presentedViewController == nil, !progress.isBeingDismissed
            {
                progress.dismiss(animated: true, completion: complete)
            } else {
                // A toast can present Transfers above this alert. Keep that
                // sheet and leave a truthful result underneath it.
                if progress.presentedViewController != nil {
                    switch result {
                    case let .success(outcome):
                        switch outcome.code {
                        case .success: progress.progressContext.purpose(message: kind.completionTitle)
                        case .cancelled: progress.progressContext.purpose(message: String(localized: "Cancelled"))
                        default: progress.progressContext.purpose(message: FailureText.title(for: outcome))
                        }
                    case let .failure(error):
                        progress.progressContext.purpose(
                            message: error is CancellationError || (error as? FilaFailure)?.code == .cancelled
                                ? String(localized: "Cancelled") : String(localized: "Operation Failed")
                        )
                    }
                }
                complete()
            }
        }
    }

    private func reportDeleteFailure(_ failure: FilaFailure, paths: [String], useTrash: Bool) {
        guard failure.code != .success, failure.code != .cancelled else { return }
        guard useTrash, failure.systemError == EROFS,
              let presenter = activePresenter else { return report(failure) }
        PermanentDeleteConfirmation.present(
            from: presenter,
            title: String(localized: "Cannot Move to Trash"),
            message: String(localized: "The trash cannot be written to. Permanently delete the selected items still at their original paths? Items already in the trash will stay there. This cannot be undone.")
        ) { self.deleteRemainingItems(at: paths) }
    }

    /// A new, explicitly confirmed deletion of the items currently at these
    /// paths. Missing names are skipped, never treated as proof of a trash move.
    private func deleteRemainingItems(at paths: [String]) {
        Task {
            do {
                var remaining: [String] = []
                for path in paths {
                    do {
                        _ = try await session.perform { try await $0.details(of: path) }
                        remaining.append(path)
                    } catch let failure as FilaFailure
                        where failure.code == .notFound || failure.systemError == ENOENT
                    {
                        continue
                    }
                }
                guard !remaining.isEmpty else { didRemove(); return }
                startDelete(remaining)
            } catch { report(error) }
        }
    }
}
