import FilaBackendUI
import Then
import UIKit

extension UIViewController {
    /// A sheet sized for where it is shown: a form sheet of the one shared
    /// size on a regular width, a full-width page sheet on a phone. One
    /// entry point, so no screen decides its own size.
    func presentAsSheet(_ viewController: UIViewController) {
        guard traitCollection.horizontalSizeClass != .regular else {
            presentAsFormSheet(viewController)
            return
        }
        viewController.modalPresentationStyle = .pageSheet
        viewController.sheetPresentationController?.do {
            $0.detents = [.large()]
            $0.prefersGrabberVisible = true
            $0.prefersScrollingExpandsWhenScrolledToEdge = true
            $0.prefersEdgeAttachedInCompactHeight = true
            $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        present(viewController, animated: true)
    }

    /// The form sheet, at `FilaUI.formSheetSize` wherever the width allows
    /// one. A compact width shows it as a page sheet regardless.
    func presentAsFormSheet(_ viewController: UIViewController) {
        viewController.modalPresentationStyle = .formSheet
        viewController.preferredContentSize = FilaUI.formSheetSize
        present(viewController, animated: true)
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
