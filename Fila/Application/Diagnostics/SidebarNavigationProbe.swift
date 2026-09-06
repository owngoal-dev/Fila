#if DEBUG
import FilaLog
import UIKit

/// Launch with -FilaSidebarRegression on an iPhone simulator. These are the
/// three location jumps that must never ask UIKit to push a column wrapper.
@MainActor
enum SidebarNavigationProbe {
    static func run(in root: RootSplitViewController) {
        Task { @MainActor in
            await FileSession.shared.ready()
            try? await Task.sleep(nanoseconds: 500_000_000)
            precondition(root.isCollapsed)
            root.presentSidebar()
            try? await Task.sleep(nanoseconds: 800_000_000)
            root.open("/etc")
            try? await Task.sleep(nanoseconds: 800_000_000)
            assert((root.content.navigation?.topViewController as? BrowserViewController)?.directory == "/etc")
            assert(root.presentedViewController == nil)
            let replacement = UIViewController()
            root.replace(replacement)
            assert(root.content.navigation?.topViewController === replacement)
            root.openFromLink("/usr")
            assert((root.content.navigation?.topViewController as? BrowserViewController)?.directory == "/usr")
            FilaLog.info("FILA_SIDEBAR_REGRESSION_PASSED")
            if ProcessInfo.processInfo.arguments.contains("-FilaDeletePreview") {
                PermanentDeleteConfirmation.present(
                    from: root, title: String(localized: "Delete Permanently?"),
                    message: String(localized: "\(2) items will be deleted and cannot be recovered.")
                ) {}
            } else {
                root.presentSidebar()
            }
        }
    }
}
#endif
