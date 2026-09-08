import Then
import UIKit

extension UIViewController {
    /// Short tasks start at medium height; lists and detail screens start large.
    func presentAsSheet(_ viewController: UIViewController, startsLarge: Bool = true, canExpand: Bool = true) {
        viewController.modalPresentationStyle = .pageSheet
        viewController.sheetPresentationController?.do {
            $0.detents = startsLarge ? [.large()] : (canExpand ? [.medium(), .large()] : [.medium()])
            $0.prefersGrabberVisible = true
            $0.prefersScrollingExpandsWhenScrolledToEdge = true
            $0.prefersEdgeAttachedInCompactHeight = true
            $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        present(viewController, animated: true)
    }

    func presentAsHalfSheet(_ viewController: UIViewController, canExpand: Bool = true) {
        presentAsSheet(viewController, startsLarge: false, canExpand: canExpand)
    }

    /// Only a presented root needs Close. Pushed screens keep the native Back.
    func installModalDoneButton() {
        navigationItem.backButtonDisplayMode = .minimal
        guard presentingViewController != nil else { return }
        guard navigationController == nil || navigationController?.viewControllers.first === self else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
    }
}
