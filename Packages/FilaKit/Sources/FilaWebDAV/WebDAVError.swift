import Foundation

/// Why a WebDAV request did not do what it was sent for, sorted by what the
/// user can do about it: fix the address or the account, wait for the
/// server, or read what the server said. An HTTP status this module has no
/// better name for stays a number inside `server`.
public enum WebDAVError: Error, Sendable, Equatable {
    /// The connection could not be made or was lost. `reason` is the
    /// transport's own wording.
    case connectionFailed(reason: String)
    /// The server's certificate is not one this device trusts: a
    /// self-signed NAS, an expired certificate, the wrong host name.
    case untrustedCertificate
    /// A plain `http` address outside the local network, which the system
    /// refuses to reach without encryption.
    case insecureAddress
    /// The server did not answer in time.
    case timedOut
    /// The server refused the account or the password, or wants one and
    /// none was given.
    case authenticationFailed
    /// The account may not do that to `path`.
    case accessDenied(path: String)
    /// Nothing is at `path`.
    case notFound(path: String)
    /// Another item already has the name at `path`.
    case alreadyExists(path: String)
    /// A removal that expected a file found a folder at `path`, or the
    /// reverse, and touched nothing.
    case wrongKind(path: String)
    /// The item at `path` is not the one that was looked at moments before:
    /// the server refused a request conditioned on it.
    case changedOnServer(path: String)
    /// The server has no room for the upload.
    case insufficientStorage
    /// The address answered, but not as a WebDAV server: a web page where a
    /// folder listing was expected, or a refusal of PROPFIND itself. Usually
    /// the address is missing its WebDAV path, such as Alist's `/dav`.
    case notWebDAV
    /// The server answered with something that cannot be read: a listing
    /// that is not XML, a reply larger than any listing should be.
    case invalidResponse
    /// The server answered with an HTTP status this module has no better
    /// name for.
    case server(status: Int, path: String?)
    /// The connection to the server was closed by this process: the profile
    /// was edited or removed while a request was waiting.
    case disconnected
    /// The server was removed from Fila while a screen still showed it.
    case removed
    /// The staging descriptor refused a write; `code` is its errno.
    case descriptorWrite(code: Int32)
    /// The source descriptor of an upload refused a read, or ended before
    /// its size; `code` is its errno.
    case descriptorRead(code: Int32)

    /// The `WebDAVError` for a transport failure of a request to `path`.
    static func map(_ error: Error) -> WebDAVError {
        if let known = error as? WebDAVError {
            return known
        }
        guard let url = error as? URLError else {
            return .connectionFailed(reason: String(describing: error))
        }
        switch url.code {
        case .timedOut:
            return .timedOut
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return .untrustedCertificate
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureAddress
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .authenticationFailed
        case .cancelled:
            return .disconnected
        default:
            return .connectionFailed(reason: url.localizedDescription)
        }
    }

    /// Whether a request that failed with the transport error `error` may
    /// still have reached the server and been acted on. A connection that
    /// was never made carried nothing; one that failed after it was up —
    /// lost, timed out, cancelled mid-flight — leaves the outcome open.
    static func mayHaveBeenSent(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return !(error is WebDAVError) }
        switch url.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL:
            return false
        default:
            return true
        }
    }
}

extension WebDAVError: LocalizedError {
    public var errorDescription: String? {
        let bundle = WebDAVBackend.bundle
        switch self {
        case .connectionFailed:
            return String(localized: "The server could not be reached. Check the address and try again.", bundle: bundle)
        case .untrustedCertificate:
            return String(localized: "The server’s certificate is not trusted by this device. Use an address with a valid certificate, or use http on a trusted network.", bundle: bundle)
        case .insecureAddress:
            return String(localized: "An http address outside the local network cannot be used. Use the server’s https address instead.", bundle: bundle)
        case .timedOut:
            return String(localized: "The server did not answer in time. Try again.", bundle: bundle)
        case .authenticationFailed:
            return String(localized: "The server refused the account name or password. Check them and try again.", bundle: bundle)
        case .accessDenied:
            return String(localized: "This account is not allowed to do that. Try another account, or choose a different item.", bundle: bundle)
        case .notFound:
            return String(localized: "That item is not on the server. Refresh the folder, or choose another item.", bundle: bundle)
        case .alreadyExists:
            return String(localized: "An item with that name already exists. Choose a different name.", bundle: bundle)
        case .wrongKind:
            return String(localized: "The item on the server is not what Fila expected. Refresh the folder and try again.", bundle: bundle)
        case .changedOnServer:
            return String(localized: "The item changed on the server. Refresh the folder and try again.", bundle: bundle)
        case .insufficientStorage:
            return String(localized: "The server is out of space. Free some space on the server and try again.", bundle: bundle)
        case .notWebDAV:
            return String(localized: "This address does not answer as a WebDAV server. Check the full address, including its path, such as /dav for Alist.", bundle: bundle)
        case .invalidResponse:
            return String(localized: "The server sent a reply Fila cannot read. Try again.", bundle: bundle)
        case .server:
            return String(localized: "The server refused this request. Try again.", bundle: bundle)
        case .disconnected:
            return String(localized: "The connection to the server was closed. Try again.", bundle: bundle)
        case .removed:
            return String(localized: "This server was removed from Fila. Add it again in Settings to open it.", bundle: bundle)
        case .descriptorWrite:
            return String(localized: "The file could not be saved on this device. Try again.", bundle: bundle)
        case .descriptorRead:
            return String(localized: "The file could not be read for upload. Try again.", bundle: bundle)
        }
    }
}
