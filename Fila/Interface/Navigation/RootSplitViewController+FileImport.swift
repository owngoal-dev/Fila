import UIKit

/// A file the system handed to Fila: *Copy to Fila* in a share sheet, or
/// Open In from another app. `CFBundleDocumentTypes` accepts every type.
///
/// The system supplies the selected file URL, which may still point into
/// another provider's storage — this app opens documents in place, so the URL
/// can be the person's own file in the Files app and not a copy. Show its
/// parent before asking where it should go, so cancelling leaves the original
/// visible.
///
/// A URL inside this app's own container is a copy the system (or the Save to
/// Fila action) already made for us: it moves into the chosen folder, which is
/// what "hand it to Fila" means. A URL anywhere else is the person's own file,
/// and it is **copied** — taking it out of the Files app is not what sharing it
/// here asked for, and it looks exactly like the file being deleted.
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
            // Which of these are ours to move, and which are the person's own
            // file that only a copy of may cross over.
            let ours = paths.filter(isInsideThisApp)
            let theirs = paths.filter { !isInsideThisApp($0) }
            // Offer the shared Inbox as the initial destination.
            let picker = SaveDestinationViewController(
                directory: URL(fileURLWithPath: FileSession.shared.local.environment.inboxDirectory ?? FileSession.shared.local.rootPath, isDirectory: true),
                message: theirs.isEmpty
                    ? String(localized: "\(listed) will be moved into the folder you choose.")
                    : String(localized: "\(listed) will be copied into the folder you choose."),
                link: session.link,
            ) { destination in
                // A file already in the chosen folder stays there: it is not
                // moved or copied onto itself.
                let home = destination.resolvingSymlinksInPath().path
                func incoming(_ paths: [String]) -> [String] {
                    paths.filter {
                        URL(fileURLWithPath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path != home
                    }
                }
                if !incoming(theirs).isEmpty {
                    session.operations.copy(incoming(theirs), to: destination.path)
                }
                if !incoming(ours).isEmpty {
                    session.operations.move(incoming(ours), to: destination.path)
                }
                self.open(destination.path, select: names.count == 1 ? names[0] : nil)
            }
            // On top of whatever is up: a share arriving while Settings is
            // open would otherwise be refused by `present` and lost.
            TopPresenter.whenReady(from: self) { $0.presentAsSheet(UINavigationController(rootViewController: picker)) }
        }
    }

    /// Whether `path` is a file this app was handed rather than the person's
    /// own: inside its container, or the App Group the Save to Fila action
    /// writes into. Resolved on both sides, because `/var` is a symlink into
    /// `/private` and a prefix test on an unresolved string is a test that
    /// answers for a path nobody opened.
    private func isInsideThisApp(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return Self.handedRoots.contains { resolved.hasPrefix($0) }
    }

    private static let handedRoots: [String] = {
        var roots = [NSHomeDirectory()]
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        {
            roots.append(group.path)
        }
        return roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
    }()
}
