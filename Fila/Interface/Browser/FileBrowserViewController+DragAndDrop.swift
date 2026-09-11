import FilaBackendUI
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
        // Other apps are offered the path as text: only this process can open
        // it, so there is no file to promise them.
        return [FileReference.local(path).dragItem(NSItemProvider(object: path as NSString))]
    }
}

extension FileBrowserViewController: UICollectionViewDropDelegate {
    func collectionView(
        _: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath indexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        // Nothing enters the trash but a delete: a dropped item would have no
        // origin to be put back to.
        guard !isTrash else { return UICollectionViewDropProposal(operation: .forbidden) }
        let operation = FileReference.proposal(for: session, into: .local(dropTarget(at: indexPath)))
        return UICollectionViewDropProposal(operation: operation, intent: .insertIntoDestinationIndexPath)
    }

    func collectionView(_: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard !isTrash else { return }
        recordDirectoryUse()
        FileDrop.receive(coordinator.items.map(\.dragItem), into: .local(dropTarget(at: coordinator.destinationIndexPath)), from: self)
    }

    /// The folder under the pointer, or this one.
    private func dropTarget(at indexPath: IndexPath?) -> String {
        if let indexPath, let node = dataSource.itemIdentifier(for: indexPath), node.isNavigable {
            return path(of: node)
        }
        return directory
    }
}
