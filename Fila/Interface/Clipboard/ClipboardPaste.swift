import FilaBackendKit
import FilaBackendUI
import UIKit

/// Paste, from any screen: one reserved clipboard snapshot, one delivery
/// (`FileDelivery` — the native job between local folders, a transfer when a
/// share is involved), one verdict for the clipboard.
///
/// Copy or move is chosen at the paste, not only at the take. A move is
/// consumed only when the whole of it succeeded. A partial move — something
/// retained, something uncertain — keeps the selection, because the batch
/// does not say which roots are gone and a guess would lose the user's only
/// way to finish the job.
@MainActor
enum ClipboardPaste {
    /// The whole flow, from the clipboard as it stands: nothing happens
    /// when it is empty or already being pasted.
    static func paste(into folder: FileReference, mode: TransferMode, from presenter: UIViewController) {
        guard let paste = FileClipboard.shared.beginPaste() else { return }
        Task {
            let delivered = await FileDelivery.deliver(paste.items.map(FileReference.init), into: folder, mode: mode, from: presenter)
            FileClipboard.shared.finishPaste(paste, moved: delivered && mode == .move)
        }
    }
}
