import UIKit

/// A file the system handed to Fila: *Copy to Fila* in a share sheet, or
/// Open In from another app. `CFBundleDocumentTypes` accepts every type.
///
/// Unlike a `fila://` link this writes — but nothing arrives here that a
/// stranger typed. The system has already copied the file into the Inbox,
/// which is the sidebar's *Inbox* (`SidebarLocation.inboxDirectory`), and the
/// only question is where it goes from there. The answer is the folder panel
/// Save To uses, and the write is a *move* out of the Inbox: the data volume
/// is one volume, so it is a rename rather than a second pass over the bytes.
/// Cancelling leaves the file in the Inbox, where it is visible and can be
/// moved later like anything else — an Inbox that silently discards is not
/// one.
extension RootSplitViewController {
    func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            let session = FileSession.shared
            await session.ready()
            let names = urls.map(\.lastPathComponent)
            let paths = urls.map(\.path)
            let listed = ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
            // Start where the file already is. The Inbox is the one folder the
            // user has not chosen and cannot have been looking at, so opening
            // on it shows the arrival rather than wherever a tab was left.
            let picker = SaveDestinationViewController(
                directory: URL(fileURLWithPath: SidebarLocation.inboxDirectory, isDirectory: true),
                message: String(localized: "\(listed) will be moved into the folder you choose."),
                link: session.link
            ) { destination in
                // The panel opens on the Inbox, which is where these already
                // are. Choosing it means "leave them here" — moving a file onto
                // its own directory is `EEXIST`, not a no-op.
                let home = destination.resolvingSymlinksInPath().path
                let moving = paths.filter {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path != home
                }
                if !moving.isEmpty {
                    session.operations.move(moving, to: destination.path)
                }
                self.open(destination.path, select: names.count == 1 ? names[0] : nil)
            }
            // On top of whatever is up: a share arriving while Settings is
            // open would otherwise be refused by `present` and lost.
            var presenter: UIViewController = self
            while let above = presenter.presentedViewController {
                presenter = above
            }
            presenter.presentAsSheet(UINavigationController(rootViewController: picker))
        }
    }
}
