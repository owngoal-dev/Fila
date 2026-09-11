import AlertController
import FilaLog
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

    /// Never with `overrideGuard`: the app offers no way past the guard.
    /// The wire field stays for the daemon's contract, and nothing here
    /// sets it.
    private func startDelete(_ paths: [String], useTrash: Bool = false) {
        if !useTrash {
            FilaLog.info("permanent delete of \(paths.count) item(s)")
            // The names at verbose and not at info, because Empty Trash comes
            // through here with everything in it — thousands of lines would
            // evict the history that explains why they were deleted. Turn the
            // log up first and the record is complete.
            for path in paths {
                FilaLog.verbose("permanent delete: \(path)")
            }
        }
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
                            started: { cover.show(job: $0, in: self.session.operations) }
                        )
                    }
                    return try await session.operations.awaitJob(
                        JobRequest(kind: .delete, sources: paths, useTrash: useTrash),
                        kind: kind,
                        subtitle: description,
                        feedback: .successOnly,
                        started: { cover.show(job: $0, in: self.session.operations) }
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
