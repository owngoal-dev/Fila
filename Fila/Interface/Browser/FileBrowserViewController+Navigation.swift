import FilaProtocol
import UIKit

// MARK: - Navigation

extension FileBrowserViewController {
    func path(of node: FileNode) -> String {
        path(ofName: node.name)
    }

    /// How this browser names a child of the folder it is showing.
    func path(ofName name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Goes to a directory — and the one rule the whole tab obeys.
    ///
    /// **A tab's navigation stack is the path.** Whatever is on screen, the
    /// stack under it is that directory's chain of ancestors, so Back always
    /// means *one component shallower* and the breadcrumb and Back can never
    /// point in different directions.
    ///
    /// Two gestures, and only two:
    ///
    /// - **Descend.** Tapping a row pushes the child it names. This is the only
    ///   push there is, and it keeps the stack the chain because a child's
    ///   chain is this folder's chain plus one.
    /// - **Jump.** Everything else that names a directory — the breadcrumb, the
    ///   sidebar's places and favorites, *Go to Path*, *Show Original*, a
    ///   `fila://` link — re-roots the tab at that path alone
    ///   (`TabContainerViewController.showRoot`): a replace, not a push, so
    ///   Back at that new root lazily opens its parent. Going to `/etc` from
    ///   `/var/mobile/Documents` must not leave Back walking back out through
    ///   somebody's Documents, and the ancestors are in the breadcrumb.
    ///
    /// Popping is the same thing as jumping to an ancestor, so an ancestor
    /// already on the stack is popped to instead — same destination, with the
    /// animation and the scroll positions that a pop keeps.
    ///
    /// What this replaced pushed *anything* not already on the stack, ancestors
    /// included. After a jump the stack held one directory, so no ancestor was
    /// ever found: from `/var/jb/bin` a tap on `jb` in the breadcrumb put
    /// `/var/jb` on top of it, and Back then walked *deeper*, into `bin`. That
    /// was the whole of "push and pop feel backwards".
    func open(directory path: String) {
        guard let navigation = navigationController else { return }
        if let existing = navigation.viewControllers
            .last(where: { ($0 as? FileBrowserViewController)?.directory == path })
        {
            navigation.popToViewController(existing, animated: true)
            return
        }
        // A child of this folder is a descent. Anything else is a jump — and
        // the shell owns those, because re-rooting is a tab-wide operation.
        // Without a shell to ask (a browser outside the window), a push is
        // still better than going nowhere.
        if (path as NSString).deletingLastPathComponent != directory, let shell {
            shell.open(path)
            return
        }
        navigation.pushViewController(FileBrowserViewController(directory: path), animated: true)
    }

    func open(_ node: FileNode) {
        // A trashed item is not somewhere to go or something to read: it is
        // put back, or it is gone. Both are in its menu.
        guard !isTrash else { return }
        if node.isNavigable {
            open(directory: path(of: node))
            return
        }
        recordDirectoryUse()
        Task { await openFile(at: path(of: node), session: session) }
    }
}
