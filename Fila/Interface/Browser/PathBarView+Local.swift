import FilaBackendUI
import UIKit

extension PathBarView {
    /// The crumbs for a directory on the local backend.
    ///
    /// The first crumb is the backend's root. For `/` that is the device,
    /// not a slash: the name when the entitlement lets us read it, the model
    /// otherwise. Inside a container it is the root's own name — nothing
    /// above Documents is offered, so nothing above it is drawn. Every crumb
    /// carries the folder picture; a browser with app artwork for a crumb
    /// swaps it in.
    @MainActor
    static func localCrumbs(for path: String) -> [Crumb] {
        let local = FileSession.shared.local
        let folder = FilePresentation.image(for: .device(.folder))
        var crumbs = [Crumb(title: "@" + UIDevice.current.name, target: "/", icon: folder)]
        var prefix = ""
        if local.rootPath != "/" {
            let roots = [local.rootPath, URL(fileURLWithPath: local.rootPath).resolvingSymlinksInPath().path]
            if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                crumbs = [Crumb(title: local.root.displayName, target: root, icon: folder)]
                prefix = root
            }
        }
        for component in path.dropFirst(prefix.count).split(separator: "/").map(String.init) {
            prefix += "/" + component
            crumbs.append(Crumb(title: component, target: prefix, icon: folder))
        }
        return crumbs
    }

    /// The crumbs for a file: its folder's crumbs and then the file itself,
    /// with `icon` — the picture its row shows.
    @MainActor
    static func localCrumbs(forFile path: String, icon: UIImage?) -> [Crumb] {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        return localCrumbs(for: directory) + [Crumb(title: name, target: path, icon: icon)]
    }
}
