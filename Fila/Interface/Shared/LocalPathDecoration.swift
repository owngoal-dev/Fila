import FilaBackendUI
import UIKit

/// The breadcrumb of a screen about one local path that is not its browser:
/// a viewer, Properties, Search, a terminal.
///
/// The folders down from the root, the item itself with the picture its row
/// shows, and then — for a screen that is about the item rather than the
/// item — the screen. A tap on a folder goes back to that folder's browser
/// when it is on the stack, which it is after a descent, and jumps there
/// otherwise; the shell decides which.
final class LocalPathDecoration: TabContentDecorationSource {
    private let path: String
    private let isDirectory: Bool
    private let icon: UIImage?
    private let screen: PathBarView.Crumb?

    /// A screen about the file at `path`, whose row shows `icon`; `screen`
    /// is the crumb for the screen itself, nil when the screen *is* the file.
    init(path: String, icon: UIImage?, screen: PathBarView.Crumb? = nil) {
        self.path = path
        isDirectory = false
        self.icon = icon
        self.screen = screen
    }

    /// A screen about the folder at `directory`.
    init(directory: String, screen: PathBarView.Crumb) {
        path = directory
        isDirectory = true
        icon = nil
        self.screen = screen
    }

    func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        let item = isDirectory
            ? PathBarView.localCrumbs(for: path)
            : PathBarView.localCrumbs(forFile: path, icon: icon)
        return item + (screen.map { [$0] } ?? [])
    }

    func tabContent(_ content: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb) {
        // A file's own crumb, under a page about it, is the file: its folder
        // is the nearest place to go.
        let target = !isDirectory && crumb.target == path ? (path as NSString).deletingLastPathComponent : crumb.target
        content.shell?.showDirectory(target, from: content)
    }
}
