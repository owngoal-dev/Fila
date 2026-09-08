import AlertController
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

    /// The one place a `FilaFailure` becomes something a person can read.
    ///
    /// `.cancelled` is not shown: the user cancelled it, they know. Everything
    /// else gets the daemon's reason plus the `errno` behind it, because on a
    /// jailbroken filesystem "Operation not permitted" as root almost always
    /// means an immutable flag, and that is only guessable from the number.
    func report(_ failure: FilaFailure) {
        guard failure.code != .success, failure.code != .cancelled else { return }
        let alert = AlertViewController(
            title: Self.failureTitle(for: failure),
            message: Self.failureMessage(for: failure)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
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

    private static func failureTitle(for failure: FilaFailure) -> String {
        switch failure.code {
        case .protectedPath: return String(localized: "Protected Item")
        case .notPermitted: return String(localized: "Not Permitted")
        case .notFound: return String(localized: "Not Found")
        case .wrongPassword: return String(localized: "Wrong Password")
        case .invalidRequest: return String(localized: "Unable to Complete Request")
        default: return String(localized: "Operation Failed")
        }
    }

    private static func failureMessage(for failure: FilaFailure) -> String {
        var lines = [FailureMessage.text(for: failure)]
        if let path = failure.path { lines.append(path) }
        return lines.joined(separator: "\n\n")
    }
}
