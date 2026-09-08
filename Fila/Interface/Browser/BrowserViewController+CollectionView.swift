import FilaProtocol
import UIKit

// MARK: - Collection view

extension BrowserViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != nil
    }

    func collectionView(_: UICollectionView, didBeginMultipleSelectionInteractionAt _: IndexPath) {
        setEditing(true, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing else {
            recordDirectoryUse()
            updateChrome()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return }
        open(node)
    }

    func collectionView(_: UICollectionView, didDeselectItemAt _: IndexPath) {
        if isEditing {
            updateChrome()
        }
    }

    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let path = path(of: node)
        let presentation = node.kind == .directory ? appFolders[node.name] : nil
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            presentation.map { AppFolderPreviewViewController(path: path, presentation: $0) }
        }) { [weak self] _ in
            self?.contextMenu(for: node)
        }
    }

    func collectionView(
        _: UICollectionView,
        willDisplayContextMenu _: UIContextMenuConfiguration,
        animator _: UIContextMenuInteractionAnimating?
    ) {
        recordDirectoryUse()
    }

    /// A job started from this menu finishes on its own schedule — the tap
    /// returns on the main thread, the delete is still an XPC round trip away —
    /// and a listing replaced while the menu is animating shut takes the row
    /// out from under the animation. It looks like the delete did nothing and
    /// left a glitch behind. Hold the reload until the menu is gone.
    func collectionView(
        _: UICollectionView,
        willEndContextMenuInteraction _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        isMenuDismissing = true
        guard let animator else { return endMenuDismissal() }
        animator.addCompletion { [weak self] in self?.endMenuDismissal() }
    }

    func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let preview = animator.previewViewController as? AppFolderPreviewViewController else { return }
        animator.addCompletion { [weak self] in
            guard let self, viewIfLoaded?.window != nil,
                  navigationController?.topViewController === self else { return }
            open(directory: preview.path)
        }
    }
}
