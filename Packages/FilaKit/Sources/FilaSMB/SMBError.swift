import Foundation
import Network
import SMBClient

/// Why an SMB operation did not happen, sorted by what the user can do
/// about it: fix the account, pick another share, wait for the server, or
/// read what the server said. The vendor's status stays inside `server`
/// rather than becoming one Swift case per NTSTATUS.
public enum SMBError: Error, Sendable, Equatable {
    /// The TCP connection could not be made or was lost. `reason` is the
    /// transport's own wording.
    case connectionFailed(reason: String)
    /// A request outlived its time budget. The session was retired, so
    /// whatever the server was doing with it is finished as far as this
    /// process is concerned.
    case timedOut(operation: String)
    /// The server refused the account or the password.
    case authenticationFailed
    /// The server has no share by that name.
    case shareNotFound(String)
    /// The account may not do that to `path`.
    case accessDenied(path: String)
    /// Nothing is at `path`.
    case notFound(path: String)
    /// Another name is already at `path`.
    case alreadyExists(path: String)
    /// The directory at `path` still has entries and was not removed.
    case directoryNotEmpty(path: String)
    /// The server answered with a status this module has no better name
    /// for; `status` is its NTSTATUS wording.
    case server(status: String, path: String?)
    /// The session was retired while this operation was waiting: a
    /// timeout, a cancellation or a disconnect elsewhere. Retrying starts a
    /// fresh session.
    case disconnected
    /// A name Fila will not put on the wire: SMB reserves `\` and a few
    /// other characters, and a `\` inside a component would be a path.
    case invalidName(String)
    /// The staging descriptor refused a write; `code` is its errno.
    case descriptorWrite(code: Int32)
    /// The source descriptor of an upload refused a read; `code` is its errno.
    case descriptorRead(code: Int32)

    /// The `SMBError` for what the vendor threw while touching `path`.
    static func map(_ error: Error, path: String?, operation: String) -> SMBError {
        if let known = error as? SMBError { return known }
        if error is CancellationError { return .disconnected }
        if let response = error as? ErrorResponse {
            let status = NTStatus(response.header.status)
            switch status {
            case .logonFailure:
                return .authenticationFailed
            case .userSessionDeleted, .networkNameDeleted, .fileClosed:
                return .disconnected
            case .badNetworkName:
                return .shareNotFound(path ?? "")
            case .accessDenied:
                return .accessDenied(path: path ?? "")
            case .objectNameNotFound, .objectPathNotFound, .noSuchFile:
                return .notFound(path: path ?? "")
            case .objectNameCollision:
                return .alreadyExists(path: path ?? "")
            case .directoryNotEmpty:
                return .directoryNotEmpty(path: path ?? "")
            default:
                return .server(status: status.description, path: path)
            }
        }
        if let connection = error as? ConnectionError {
            switch connection {
            case .cancelled, .disconnected:
                return .disconnected
            default:
                return .connectionFailed(reason: String(describing: connection))
            }
        }
        if let network = error as? NWError {
            return .connectionFailed(reason: network.localizedDescription)
        }
        return .connectionFailed(reason: String(describing: error))
    }

    /// Whether the session that produced this error is worth keeping. A
    /// server's refusal of one path leaves the session fine; a transport
    /// failure does not.
    var retiresSession: Bool {
        switch self {
        case .connectionFailed, .timedOut, .disconnected: return true
        default: return false
        }
    }
}

extension SMBError: LocalizedError {
    public var errorDescription: String? {
        let bundle = SMBBackend.bundle
        switch self {
        case .connectionFailed:
            return String(localized: "The server could not be reached. Check the address and try again.", bundle: bundle)
        case .timedOut:
            return String(localized: "The server did not answer in time. Try again.", bundle: bundle)
        case .authenticationFailed:
            return String(localized: "The server refused the account name or password. Check them and try again.", bundle: bundle)
        case let .shareNotFound(share):
            return String(localized: "The server has no share named “\(share)”. Choose another share.", bundle: bundle)
        case .accessDenied:
            return String(localized: "This account is not allowed to do that. Try another account, or choose a different item.", bundle: bundle)
        case .notFound:
            return String(localized: "That item is not on the server. Refresh the folder, or choose another item.", bundle: bundle)
        case .alreadyExists:
            return String(localized: "An item with that name already exists. Choose a different name.", bundle: bundle)
        case .directoryNotEmpty:
            return String(localized: "The folder on the server is not empty. Remove its contents first.", bundle: bundle)
        case .server:
            return String(localized: "The server refused this request. Try again.", bundle: bundle)
        case .disconnected:
            return String(localized: "The connection to the server was closed. Try again.", bundle: bundle)
        case let .invalidName(name):
            return String(localized: "The name “\(name)” cannot be used on this server. Choose a different name.", bundle: bundle)
        case .descriptorWrite:
            return String(localized: "The file could not be saved on this device. Try again.", bundle: bundle)
        case .descriptorRead:
            return String(localized: "The file could not be read for upload. Try again.", bundle: bundle)
        }
    }
}
