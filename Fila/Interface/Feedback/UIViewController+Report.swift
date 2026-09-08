import AlertController
import FilaProtocol
import UIKit

extension UIViewController {
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
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    private static func failureTitle(for failure: FilaFailure) -> String {
        switch failure.code {
        case .protectedPath: String(localized: "Protected Item")
        case .notPermitted: String(localized: "Not Permitted")
        case .notFound: String(localized: "Not Found")
        case .wrongPassword: String(localized: "Wrong Password")
        case .invalidRequest: String(localized: "Unable to Complete Request")
        default: String(localized: "Operation Failed")
        }
    }

    private static func failureMessage(for failure: FilaFailure) -> String {
        var lines = [FailureMessage.text(for: failure)]
        if let path = failure.path {
            lines.append(path)
        }
        return lines.joined(separator: "\n\n")
    }
}
