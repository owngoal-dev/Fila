import FilaFormats
import FilaProtocol
import Foundation

/// The one place an error becomes a sentence a person can read.
///
/// `FilaFailure` and `FormatFailure` are both plain `Error`s, deliberately: they
/// live in packages that carry no localisation and cross no user interface. The
/// cost of that is `localizedDescription` on either producing
/// *“The operation couldn’t be completed. (FilaProtocol.FilaFailure error 1.)”*,
/// which is the exact string that makes an app look broken at the moment it is
/// trying to explain itself. Every user-facing failure goes through here so that
/// never reaches a screen.
enum FailureMessage {
    /// `whileWriting` changes only the sentences where writing is what makes the
    /// refusal make sense. The guard refuses to *replace* a file the device
    /// needs to boot; it never refuses to read one, so the same code means two
    /// different things depending on which way the bytes were going.
    static func text(for error: Error, whileWriting: Bool = false) -> String {
        switch error {
        case let failure as FilaFailure: return message(for: failure, whileWriting: whileWriting)
        case let failure as FormatFailure: return message(for: failure)
        default: return error.localizedDescription
        }
    }

    private static func message(for failure: FilaFailure, whileWriting: Bool) -> String {
        var lines: [String] = []
        switch failure.code {
        case .protectedPath:
            lines.append(whileWriting
                ? String(localized: "The device needs this item to start up, so Fila will not replace it. You can still edit what is inside it.")
                : String(localized: "The device needs this item to start up, so Fila will not delete, move or replace it. You can still edit what is inside it."))
        case .notPermitted:
            lines.append(String(localized: "Fila does not have permission to do this."))
        case .notFound:
            lines.append(String(localized: "This item no longer exists."))
        case .cancelled:
            lines.append(String(localized: "Cancelled."))
        case .invalidRequest:
            lines.append(String(localized: "Fila could not complete this request. Try again."))
        case .wrongPassword:
            lines.append(String(localized: "The archive password is missing or incorrect. Enter the password and try again."))
        case .success, .operationFailed:
            break
        }
        // The number is the useful half on a jailbroken filesystem: “Operation
        // not permitted” as root almost always means an immutable flag, and
        // that is only guessable from the errno.
        if let reason = failure.systemErrorDescription { lines.append(reason) }
        if lines.isEmpty { lines.append(String(localized: "The operation failed. Try again.")) }
        return lines.joined(separator: "\n")
    }

    private static func message(for failure: FormatFailure) -> String {
        switch failure {
        case .notRecognised:
            return String(localized: "This file could not be opened. Open it as hex to see its contents.")
        case let .damaged(detail):
            return String(format: String(localized: "This file is damaged: %@."), detail)
        case let .unsupported(detail):
            return String(format: String(localized: "Fila does not support this: %@."), detail)
        case let .tooLarge(byteCount, limit):
            return String(
                format: String(localized: "This file is too large (%@). The viewer supports files up to %@."),
                FilePresentation.byteLabel(byteCount),
                FilePresentation.byteLabel(limit)
            )
        case .cancelled:
            return String(localized: "Cancelled.")
        case .wrongPassword:
            return String(localized: "The archive password is missing or incorrect. Enter the password and try again.")
        case let .system(code):
            return String(
                format: String(localized: "The operation failed: %@."),
                String(cString: strerror(code))
            )
        }
    }
}
