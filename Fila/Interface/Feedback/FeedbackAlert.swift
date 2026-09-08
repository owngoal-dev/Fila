import AlertController
import FilaLog
import UIKit

/// Failures outliving their source screen still need a reason and a Close button.
@MainActor
enum FeedbackAlert {
    static func show(_ title: String, message: String) {
        // Let the operation's progress observer dismiss its completed card first.
        DispatchQueue.main.async { present(title, message: message) }
    }

    private static func present(_ title: String, message: String) {
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            FilaLog.error("\(title): \(message)")
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let transition = presenter.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in show(title, message: message) })
        {
            return
        }
        let alert = AlertViewController(title: title, message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Close"), attribute: .accent) { context.dispose() }
        }
        presenter.present(alert, animated: true)
    }
}
