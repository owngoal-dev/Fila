import FilaProtocol
import Foundation

/// A `FilaFailure` in words, for the surfaces that are not an alert.
///
/// Deliberately the same sentences `UIViewController.report(_:)` puts in its
/// alert, so that the toast, the transfers row and the alert do not each
/// describe the same errno differently. Those private helpers collapse into
/// this one when the last alert goes.
enum FailureText {
    static func title(for failure: FilaFailure) -> String {
        switch failure.code {
        case .protectedPath: String(localized: "Protected Item")
        case .notPermitted: String(localized: "Not Permitted")
        case .notFound: String(localized: "Not Found")
        case .wrongPassword: String(localized: "Wrong Password")
        case .invalidRequest: String(localized: "Unable to Complete Request")
        default: String(localized: "Operation Failed")
        }
    }

    /// Why it failed, with the `strerror(3)` behind it rather than the number.
    /// On a jailbroken filesystem "Operation not permitted" as root almost
    /// always means an immutable flag, and that is only readable as words.
    static func summary(for failure: FilaFailure) -> String {
        var parts: [String] = []
        switch failure.code {
        case .protectedPath:
            parts.append(String(localized: "The device needs this item to start up, so Fila will not delete, move or replace it. You can still edit what is inside it."))
        case .notPermitted:
            parts.append(String(localized: "Fila does not have permission to do this."))
        case .notFound:
            parts.append(String(localized: "This item no longer exists."))
        case .wrongPassword:
            parts.append(String(
                localized: "The archive password is missing or incorrect. Enter the password and try again."
            ))
        default:
            break
        }
        if let reason = failure.systemErrorDescription {
            parts.append(reason)
        }
        if parts.isEmpty {
            parts.append(title(for: failure))
        }
        return parts.joined(separator: " · ")
    }
}
