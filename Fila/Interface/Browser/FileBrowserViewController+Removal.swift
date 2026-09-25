import FilaProtocol
import UIKit

/// When a deleted row leaves the list.
///
/// Waiting for the folder to be listed again made a delete look undone: the
/// swipe closed back over the row, the context menu flew its preview back
/// into the cell, and the row sat there for the length of the job and a
/// listing before it went. Worse, a listing that had read the folder just
/// before the job moved the item put it back after it had gone. So the row
/// goes at the tap, and stays gone for every listing that may have read the
/// folder while it was still there; the first listing started after the job
/// ended shows what is really there — including an item whose delete failed.
extension FileBrowserViewController: RemovalTracking {
    func removalWillStart(_ paths: [String]) {
        let names = names(in: paths)
        guard !names.isEmpty else { return }
        removingNames.formUnion(names)
        for name in names {
            removedNames[name] = nil
        }
        if holdsReloads {
            rearrangesWhenMenuCloses = true
        } else {
            rearrange(animated: true)
        }
    }

    func removalDidEnd(_ paths: [String]) {
        let names = names(in: paths)
        guard !names.isEmpty else { return }
        for name in names where removingNames.remove(name) != nil {
            removedNames[name] = listingGeneration
        }
        reload()
    }

    /// A listing numbered `generation` completed: rows whose job ended
    /// before it started are now whatever it found.
    func listingDidComplete(generation: Int) {
        let cleared = Set(removedNames.filter { $0.value < generation }.keys)
        guard !cleared.isEmpty else { return }
        for name in cleared {
            removedNames[name] = nil
        }
        if items.contains(where: { cleared.contains($0.name) }) {
            rearrange(animated: true)
        }
    }

    /// The context menu is gone; what was put off for it happens now.
    func contextMenuDidClose() {
        holdsReloads = false
        guard rearrangesWhenMenuCloses else { return }
        rearrangesWhenMenuCloses = false
        rearrange(animated: true)
    }

    /// A menu closing over a row that is being removed fades where it is
    /// instead of flying back into the cell it is about to leave.
    func removalDismissalPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let name = configuration.identifier as? String,
              let index = visible.firstIndex(where: { $0.name == name }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return nil }
        guard removingNames.contains(name) || removedNames[name] != nil else {
            // What UIKit shows when this method is not implemented.
            return UITargetedPreview(view: cell)
        }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let target = UIPreviewTarget(
            container: collectionView,
            center: cell.center,
            transform: CGAffineTransform(scaleX: 0.2, y: 0.2),
        )
        return UITargetedPreview(view: UIView(frame: cell.bounds), parameters: parameters, target: target)
    }

    private func names(in paths: [String]) -> Set<String> {
        Set(paths.compactMap { candidate in
            let name = (candidate as NSString).lastPathComponent
            return path(ofName: name) == candidate ? name : nil
        })
    }
}
