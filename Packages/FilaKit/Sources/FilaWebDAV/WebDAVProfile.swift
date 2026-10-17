import FilaBackendKit
import Foundation

/// One saved WebDAV server: everything about it except the password.
///
/// The server is named by one address — `https://host:port/path` — because
/// that is how every WebDAV server documents itself: Alist serves at
/// `/dav`, Nextcloud at `/remote.php/dav/files/<user>`, a NAS at whatever
/// its settings page shows. Splitting it into host, port and folder fields
/// would only make the user take apart a URL they were given whole.
///
/// `id` is the backend's identity. It is minted when the profile is first
/// saved and survives a renamed server, a changed account and a changed
/// password; it does not survive a different address, because that names a
/// different filesystem and a bookmark saved on one must not be read as a
/// path on the other. `namesSameServer(as:)` says which.
public struct WebDAVProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// What the sidebar calls it; the address's host when empty.
    public var name: String
    /// The address as typed, trimmed. `baseURL` is its parsed form.
    public var address: String
    /// Nil connects without an account: the setup screen stores an empty
    /// field as nil, so there is no account whose name is blank.
    public var username: String?

    public init(id: UUID = UUID(), name: String, address: String, username: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
    }

    /// The server's root collection, with a trailing slash so a child is
    /// resolved inside it. Nil when `address` is not a usable `http` or
    /// `https` URL; `validationFailure` says why.
    public var baseURL: URL? {
        guard validationFailure == nil, var components = URLComponents(string: address) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url
    }

    /// The name the sidebar shows: the user's, or the server's host.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return trimmed
        }
        return URLComponents(string: address)?.host ?? address
    }

    /// Where the server is and who opens it, for the settings list. Not
    /// localized: it is an address and an account name.
    public var detail: String {
        "\(address) · \(username ?? "anonymous")"
    }

    /// Whether `other` names the same filesystem: the same scheme, host,
    /// port and folder. A profile edited into another namespace becomes a
    /// new backend.
    public func namesSameServer(as other: WebDAVProfile) -> Bool {
        guard let mine = baseURL, let theirs = other.baseURL else { return false }
        return mine.scheme == theirs.scheme
            && mine.host == theirs.host
            && Self.effectivePort(mine) == Self.effectivePort(theirs)
            && mine.path == theirs.path
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }

    /// The backend ID this profile registers under.
    public var backendID: BackendID {
        BackendID("webdav:" + id.uuidString)
    }

    /// The credential-store key of this profile's password.
    public var credentialKey: String {
        "wiki.qaq.fila.webdav." + id.uuidString
    }

    /// The preference key of this backend's bookmarks and history.
    public var preferencesKey: String {
        "wiki.qaq.fila.webdav." + id.uuidString + ".preferences"
    }

    /// Nil when the address is usable; otherwise why not, for the setup
    /// screen. An account name and password in the address are refused:
    /// they belong in the fields, where the password goes to the keychain
    /// instead of the profile list.
    public var validationFailure: ValidationFailure? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .addressMissing
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return .schemeUnsupported
        }
        guard let host = components.host, !host.isEmpty else { return .addressInvalid }
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
            return .addressInvalid
        }
        if let port = components.port, !(1 ... 65535).contains(port) {
            return .addressInvalid
        }
        return nil
    }

    public enum ValidationFailure: Equatable, Sendable {
        case addressMissing
        case schemeUnsupported
        case addressInvalid
    }
}

/// The saved profiles, as one record so an edit to one is a read-modify-
/// write of the list under one key. Versioned for a later layout change;
/// there is nothing older to migrate.
public struct WebDAVProfileList: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [WebDAVProfile]

    public init(profiles: [WebDAVProfile] = []) {
        version = Self.currentVersion
        self.profiles = profiles
    }

    /// The `DefaultStorage` key of the list in the process's defaults.
    public static let storageKey = "wiki.qaq.fila.webdav.profiles"
}
