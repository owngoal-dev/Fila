import FilaBackendUI
import Then
import UIKit

extension UIViewController {
    /// Every sheet the app presents: the one form sheet, at
    /// `FilaUI.formSheetSize`, so Settings, Tasks, a server's setup, the
    /// compress form and the pickers are the same card and one replacing
    /// another does not step. One entry point, so no screen decides its own
    /// size or style.
    ///
    /// UIKit shows a form sheet as a full-width sheet wherever the window is
    /// compact, which is what a phone needs; the grabber and detents are set
    /// for that shape there. The *window's* width class decides, not the
    /// presenter's: the sidebar column and a screen inside another sheet are
    /// compact on an iPad whose window is not, and a sheet sized for them
    /// came out a page sheet twice the size of Settings.
    func presentAsSheet(_ viewController: UIViewController) {
        viewController.modalPresentationStyle = .formSheet
        viewController.preferredContentSize = FilaUI.formSheetSize
        let window = viewIfLoaded?.window?.traitCollection ?? traitCollection
        if window.horizontalSizeClass == .compact {
            viewController.sheetPresentationController?.do {
                $0.detents = [.large()]
                $0.prefersGrabberVisible = true
                $0.prefersScrollingExpandsWhenScrolledToEdge = true
                $0.prefersEdgeAttachedInCompactHeight = true
                $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            }
        }
        present(viewController, animated: true)
    }

    /// The same sheet; the name survives for the callers that asked for
    /// the form sheet by name.
    func presentAsFormSheet(_ viewController: UIViewController) {
        presentAsSheet(viewController)
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
