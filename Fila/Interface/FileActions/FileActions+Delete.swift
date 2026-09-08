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
            // A folder of ten thousand files and a cross-volume trash both take
            // minutes, and this is the card that says so.
            let cover = jobCover()
            let result: Result<FilaFailure, Error>
            do {
                let outcome = try await withSourceLocked {
                    if useTrash {
                        return try await session.operations.trash(
                            paths,
                            feedback: .successOnly,
                            started: cover.show
                        )
                    }
                    return try await session.operations.awaitJob(
                        JobRequest(kind: .delete, sources: paths, useTrash: useTrash, overrideGuard: overrideGuard),
                        kind: kind,
                        subtitle: description,
                        feedback: .successOnly,
                        started: cover.show
                    )
                }
                result = .success(outcome)
            } catch { result = .failure(error) }

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
            cover.settle(complete)
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
