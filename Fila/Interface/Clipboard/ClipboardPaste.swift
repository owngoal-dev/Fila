import AlertController
import FilaBackendKit
import FilaClient
import FilaProtocol
import UIKit

/// Paste, for every destination that is not the local browser's own job:
/// a remote folder, or local items going to a share, or share items coming
/// home. One reserved clipboard snapshot, one transfer through the
/// operation centre, one verdict for the clipboard and one sentence for
/// the user.
///
/// A cut is consumed only when the whole move succeeded. A partial move —
/// something retained, something uncertain — keeps the selection, because
/// the batch does not say which roots are gone and a guess would lose the
/// user's only way to finish the job.
@MainActor
enum ClipboardPaste {
    /// The whole flow, from the clipboard as it stands: nothing happens
    /// when it is empty or already being pasted.
    static func paste(into destination: FileLocation, from presenter: UIViewController) {
        guard let paste = FileClipboard.shared.beginPaste() else { return }
        Task { await transfer(paste, into: destination, from: presenter) }
    }

    /// Runs a reserved paste. `presenter` is asked about replacing what is
    /// in the way, once, and shows the failure if there is one.
    static func transfer(_ paste: FileClipboard.Paste, into destination: FileLocation, from presenter: UIViewController) async {
        let mode: TransferMode = paste.isCut ? .move : .copy
        let center = FileSession.shared.operations
        var outcome = await center.transfer(paste.items, into: destination, mode: mode, policy: .failIfExists)
        if case WriteFailure.alreadyExists? = outcome.failure, await confirmReplacement(from: presenter) {
            outcome = await center.transfer(paste.items, into: destination, mode: mode, policy: .replace)
        }
        FileClipboard.shared.finishPaste(paste, succeeded: outcome.succeeded)
        guard let failure = outcome.failure, !outcome.wasCancelled else { return }
        var message = FailureMessage.text(for: failure)
        if outcome.publishedFiles > 0 || failure is TransferShortfall {
            message += "\n\n" + String(localized: "Check the source and destination folders before trying again. Some items may already have been transferred.")
        }
        FeedbackAlert.show(
            mode == .move ? String(localized: "Unable to Move Items") : String(localized: "Unable to Copy Items"),
            message: message
        )
    }

    /// The cross-backend replacement question: a file is replaced by the
    /// server's one rename, a folder is filled rather than replaced.
    private static func confirmReplacement(from presenter: UIViewController) async -> Bool {
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return false }
        return await withCheckedContinuation { continuation in
            // The answer is owned by the card's actions. A card torn down
            // with its presenter — a tab closed, a sheet dismissed — never
            // runs either action, and a paste waiting on it would hold the
            // clipboard for the rest of the session; releasing the answer
            // is then the answer, and it is No.
            let answer = Answer(continuation)
            let alert = AlertViewController(
                title: String.LocalizationValue("Replace Existing Items?"),
                message: String.LocalizationValue("Files with the same names will be replaced; this cannot be undone. Folders with the same names are merged, and what they already hold is kept.")
            ) { context in
                context.addAction(title: String.LocalizationValue("Cancel")) {
                    context.dispose { answer.resume(false) }
                }
                context.addAction(title: String.LocalizationValue("Replace"), attribute: .accent) {
                    context.dispose { answer.resume(true) }
                }
            }
            presenter.present(alert, animated: true)
        }
    }

    /// Resumes its continuation exactly once: from whichever action ran,
    /// or with No when nothing ran and the card is gone.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }

        deinit {
            resume(false)
        }
    }
}
