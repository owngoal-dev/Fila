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
        case let .connectionFailed(reason):
            return String(localized: "The server could not be reached. \(reason)", bundle: bundle)
        case .timedOut:
            return String(localized: "The server did not answer in time.", bundle: bundle)
        case .authenticationFailed:
            return String(localized: "The server refused the account name or password.", bundle: bundle)
        case let .shareNotFound(share):
            return String(localized: "The server has no share named “\(share)”.", bundle: bundle)
        case .accessDenied:
            return String(localized: "The account is not allowed to do that.", bundle: bundle)
        case .notFound:
            return String(localized: "There is nothing at that path on the server.", bundle: bundle)
        case .alreadyExists:
            return String(localized: "Something with that name is already there.", bundle: bundle)
        case .directoryNotEmpty:
            return String(localized: "The folder on the server is not empty.", bundle: bundle)
        case let .server(status, _):
            return String(localized: "The server refused: \(status).", bundle: bundle)
        case .disconnected:
            return String(localized: "The connection to the server was closed. Try again to reconnect.", bundle: bundle)
        case let .invalidName(name):
            return String(localized: "“\(name)” is not a name an SMB server accepts.", bundle: bundle)
        case let .descriptorWrite(code):
            return String(localized: "The downloaded data could not be written locally (error \(code)).", bundle: bundle)
        case let .descriptorRead(code):
            return String(localized: "The file to upload could not be read locally (error \(code)).", bundle: bundle)
        }
    }
}
