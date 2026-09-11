import UIKit

/// The controller on top of everything, for something that arrives from
/// outside the screen it lands on: a failure outliving its screen, a file
/// handed over by another app.
///
/// Never a progress card: the card takes itself down when its work ends, and
/// with a controller stacked on it that dismissal takes the controller
/// instead and leaves the card up. Nor mid-transition, nor while no scene is
/// active. Until then it asks again.
@MainActor
enum TopPresenter {
    /// `root` is the window's root to start from; nil for the active scene's.
    static func whenReady(from root: UIViewController? = nil, _ present: @escaping (UIViewController) -> Void) {
        // ponytail: polls; give the card a waiter list if the delay shows.
        let retry = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenReady(from: root, present) } }
        guard var top = root ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController
        else { return retry() }
        while let presented = top.presentedViewController {
            top = presented
        }
        guard top.transitionCoordinator == nil,
              !top.children.contains(where: { $0 is OperationCoverViewController })
        else { return retry() }
        present(top)
    }
}
