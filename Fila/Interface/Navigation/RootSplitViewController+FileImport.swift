import UIKit

/// A file the system handed to Fila: *Copy to Fila* in a share sheet, or
/// Open In from another app. `CFBundleDocumentTypes` accepts every type.
///
/// The system supplies the selected file URL, which may still point into
/// another provider's storage. Show its parent before asking where to move it,
/// so cancelling leaves the original visible. Save to Fila's action extension
/// separately copies into the shared Inbox without opening this picker.
extension RootSplitViewController {
    func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            let session = FileSession.shared
            await session.ready()
            if let first = urls.first {
                self.open(first.deletingLastPathComponent().path, select: first.lastPathComponent)
            }
            let names = urls.map(\.lastPathComponent)
            let paths = urls.map(\.path)
            let listed = ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
            // Offer the shared Inbox as the initial destination.
            let picker = SaveDestinationViewController(
                directory: URL(fileURLWithPath: FileSession.shared.local.environment.inboxDirectory ?? FileSession.shared.local.rootPath, isDirectory: true),
                message: String(localized: "\(listed) will be moved into the folder you choose."),
                link: session.link
            ) { destination in
                // A file already in the chosen folder stays there.
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
            TopPresenter.whenReady(from: self) { $0.presentAsSheet(UINavigationController(rootViewController: picker)) }
        }
    }
}
