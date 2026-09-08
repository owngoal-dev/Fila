import AlertController
import UIKit

@MainActor
enum PermanentDeleteConfirmation {
    static func present(
        from presenter: UIViewController,
        title: String,
        message: String,
        confirmTitle: String = String(localized: "Delete Permanently"),
        confirm: @escaping () -> Void
    ) {
        let accent = AlertControllerConfiguration.accentColor
        AlertControllerConfiguration.accentColor = .systemRed
        defer { AlertControllerConfiguration.accentColor = accent }
        let alert = AlertViewController(title: title, message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: confirmTitle, attribute: .accent) {
                context.dispose { confirm() }
            }
        }
        presenter.present(alert, animated: true)
    }
}
