import FilaProtocol
import Then
import UIKit

extension UIViewController {
    /// The shell, from anywhere: a column of it, a stack inside a column, or a
    /// sheet it presented. The window's root is what it is, and a sheet has no
    /// `splitViewController` to walk up to — which is exactly the case the
    /// sidebar is in on a phone.
    var shell: RootSplitViewController? {
        view.window?.rootViewController as? RootSplitViewController
    }

    /// Points a sheet or share controller at something on iPad, where a popover
    /// without an anchor is a crash rather than a layout problem.
    func anchor(_ controller: UIViewController, to view: UIView) {
        controller.popoverPresentationController?.do {
            $0.sourceView = view
            $0.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 0,
                height: 0
            )
        }
    }

    /// Shows a file: the viewer the registry picks, pushed into the tab it was
    /// opened from.
    ///
    /// One branch, and the same one on every shape of screen. A viewer used to
    /// go into a third column beside the browser on an iPad; it fills the tab
    /// now, which is what "a tab can be covered by a preview, an editor or a
    /// terminal" means — and it is what lets Back out of a viewer land in the
    /// folder it came from rather than in a panel that never went away.
    func openFile(at path: String, session: FileSession) async {
        do {
            let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
            AppPreferences.shared.noteVisit(path, isDirectory: details.node.isNavigable)
            await openFile(details, session: session)
        } catch let failure as FilaFailure {
            report(failure)
        } catch {}
    }

    /// The same dispatcher when the caller already holds the item's details.
    func openFile(_ details: FileDetails, session: FileSession) async {
        let shell = shell
        let navigation = navigationController ?? shell?.content.navigation
        let source = navigation?.topViewController
        let viewer = await ViewerRegistry.makeViewer(for: details, link: session.link)
            ?? PropertiesViewController(details: details, link: session.link)
        // Opening may await the backend. A later tap or tab switch must not
        // put this document on a different page's navigation stack.
        guard !Task.isCancelled, let navigation,
              navigation.topViewController === source,
              navigation.viewIfLoaded?.window != nil else { return }
        if navigationController != nil {
            navigation.pushViewController(viewer, animated: true)
        } else {
            shell?.push(viewer)
        }
    }
}
