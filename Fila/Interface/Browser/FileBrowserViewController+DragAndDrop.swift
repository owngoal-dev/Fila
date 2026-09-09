import FilaProtocol
import UIKit

// MARK: - Drag and drop

extension FileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(
        _: UICollectionView,
        itemsForBeginning _: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        // A trashed item leaves the trash by Put Back, which knows where it
        // belongs; a drag would carry its origin note along as junk.
        guard !isTrash, let node = dataSource.itemIdentifier(for: indexPath) else { return [] }
        recordDirectoryUse()
        let path = path(of: node)
        let item = UIDragItem(itemProvider: NSItemProvider(object: path as NSString))
        // The local object is what a drop inside the app actually acts on: only
        // this process can open these paths, so nothing useful crosses the app
        // boundary and there is no point promising it.
        item.localObject = path
        return [item]
    }
}

extension FileBrowserViewController: UICollectionViewDropDelegate {
    func collectionView(
        _: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath indexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .cancel) }
        // Nothing enters the trash but a delete: a dropped item would have no
        // origin to be put back to.
        guard !isTrash else { return UICollectionViewDropProposal(operation: .forbidden) }
        // The same rule the drop applies, shown while the finger is still
        // down: a selection dragged around its own folder, or onto itself,
        // has nowhere to go, and the badge must say so rather than promise a
        // copy that the drop then silently declines.
        let sources = session.items.compactMap { $0.localObject as? String }
        guard !droppable(sources, into: dropTarget(at: indexPath)).isEmpty else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .copy, intent: .insertIntoDestinationIndexPath)
    }

    func collectionView(_: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let sources = coordinator.items.compactMap { $0.dragItem.localObject as? String }
        let target = dropTarget(at: coordinator.destinationIndexPath)
        let moved = droppable(sources, into: target)
        guard !moved.isEmpty else { return }
        recordDirectoryUse()
        promptDrop(sources: moved, target: target)
    }

    /// The folder under the pointer, or this one.
    private func dropTarget(at indexPath: IndexPath?) -> String {
        if let indexPath, let node = dataSource.itemIdentifier(for: indexPath), node.isNavigable {
            return path(of: node)
        }
        return directory
    }

    /// Per item, not for the whole drop: dragging a folder together with
    /// three files onto that folder is a real request for the three, and
    /// dropping the rest of a selection must not be cancelled by the one
    /// item that happens to be the destination.
    private func droppable(_ sources: [String], into target: String) -> [String] {
        sources.filter { $0 != target && ($0 as NSString).deletingLastPathComponent != target }
    }
}
