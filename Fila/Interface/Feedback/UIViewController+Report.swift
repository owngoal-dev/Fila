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
        presentMessage(FailureText.title(for: failure), message: Self.failureMessage(for: failure))
    }

    /// A title, a reason and OK — the shape of every failure and notice with
    /// nothing to choose. Both strings arrive resolved: a title is looked up by
    /// its caller, and a reason is computed copy, never a catalogue key.
    func presentMessage(_ title: String, message: String) {
        let alert = AlertViewController(title: title, message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    private static func failureMessage(for failure: FilaFailure) -> String {
        var lines = [FailureMessage.text(for: failure)]
        if let path = failure.path {
            lines.append(path)
        }
        return lines.joined(separator: "\n\n")
    }
}
