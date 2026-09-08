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
        case let failure as FilaFailure: message(for: failure, whileWriting: whileWriting)
        case let failure as FormatFailure: message(for: failure)
        default: error.localizedDescription
        }
    }

    private static func message(for failure: FilaFailure, whileWriting: Bool) -> String {
        if let reason = failure.reason {
            switch reason {
            case .sameLocation:
                return String(localized: "This item is already in the destination folder. Choose another folder.")
            case .sameItem: return String(localized: "The source and destination refer to the same item, even though their paths differ. Choose another destination.")
            case .insideSource: return String(localized: "A folder cannot be copied or moved into itself or one of its subfolders. Choose a destination outside this folder.")
            case .overlappingSources: return String(localized: "The selection includes the same item more than once, or both a folder and an item inside it. Select each item only once.")
            case .conflictingNames: return String(localized: "Two selected items have the same name and would use the same destination. Rename one or transfer them separately.")
            case .differentItemKinds: return String(localized: "A file and a folder have the same name at the destination. Rename one or choose another folder.")
            }
        }
        switch failure.systemError {
        case ENOSPC: return String(localized: "There is not enough free space to finish this operation safely. Free up space or choose another destination.")
        case EROFS: return String(localized: "The destination is read-only. Choose a writable folder.")
        case ENOTEMPTY: return String(localized: "The destination folder is not empty and cannot be replaced. Rename the item or choose another folder.")
        case ENOTDIR:
            return String(
                localized: "Part of the path is a file instead of a folder. Choose an existing destination folder."
            )
        case ELOOP: return String(localized: "A symbolic link in this path cannot be followed for this operation. Choose a direct path to the item.")
        default: break
        }
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
            lines.append(
                String(localized: "The archive password is missing or incorrect. Enter the password and try again.")
            )
        case .success, .operationFailed:
            break
        }
        // The number is the useful half on a jailbroken filesystem: “Operation
        // not permitted” as root almost always means an immutable flag, and
        // that is only guessable from the errno.
        if let reason = failure.systemErrorDescription {
            lines.append(reason)
        }
        if lines.isEmpty {
            lines.append(String(localized: "The operation failed. Try again."))
        }
        return lines.joined(separator: "\n")
    }

    private static func message(for failure: FormatFailure) -> String {
        switch failure {
        case .notRecognised:
            String(localized: "This file could not be opened. Open it as hex to see its contents.")
        case let .damaged(detail):
            String(format: String(localized: "This file is damaged: %@."), detail)
        case let .unsupported(detail):
            String(format: String(localized: "Fila does not support this: %@."), detail)
        case let .tooLarge(byteCount, limit):
            String(
                format: String(localized: "This file is too large (%@). The viewer supports files up to %@."),
                FilePresentation.byteLabel(byteCount),
                FilePresentation.byteLabel(limit)
            )
        case .cancelled:
            String(localized: "Cancelled.")
        case .wrongPassword:
            String(localized: "The archive password is missing or incorrect. Enter the password and try again.")
        case let .system(code):
            String(
                format: String(localized: "The operation failed: %@."),
                String(cString: strerror(code))
            )
        }
    }
}
