import FilaBackendUI
import FilaBackendKit
import FilaProtocol
import UIKit

// MARK: - Collection view

extension FileBrowserViewController: UICollectionViewDelegate {
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
        let decoration = node.kind == .directory ? appFolders[node.name] : nil
        // Named, so the dismissal can tell whether its row is being deleted.
        return UIContextMenuConfiguration(identifier: node.name as NSString, previewProvider: {
            decoration.map { FolderDecorationPreviewViewController(path: path, decoration: $0) }
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
    /// left a glitch behind. Hold the reload until the menu is gone; a delete
    /// chosen from the menu takes its row away then (see `RemovalTracking`).
    func collectionView(
        _: UICollectionView,
        willEndContextMenuInteraction _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        holdsReloads = true
        guard let animator else {
            contextMenuDidClose()
            return
        }
        animator.addCompletion { [weak self] in self?.contextMenuDidClose() }
    }

    /// The deprecated form, because the menu itself is still made by the
    /// deprecated `contextMenuConfigurationForItemAt`: UIKit stops calling
    /// all of them once any of their iOS 16 replacements is implemented.
    func collectionView(
        _: UICollectionView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        removalDismissalPreview(for: configuration)
    }

    func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let preview = animator.previewViewController as? FolderDecorationPreviewViewController else { return }
        animator.addCompletion { [weak self] in
            guard let self, viewIfLoaded?.window != nil,
                  navigationController?.topViewController === self else { return }
            open(directory: preview.path)
        }
    }
}
