import FilaBackendKit
import Foundation

/// One saved SMB share: everything about it except the password.
///
/// `id` is the backend's identity. It is minted when the profile is first
/// saved and survives a renamed share, a changed account and a changed
/// password; it does not survive a different host, port or share, because
/// those name a different filesystem and a bookmark saved on one must not be
/// read as a path on the other. `SMBProfile.rebinding` says which.
public struct SMBProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// What the sidebar calls it; the share's own name when empty.
    public var name: String
    public var host: String
    public var port: Int
    public var share: String
    /// The account's domain or workgroup, when the server needs one.
    public var domain: String?
    /// Nil is a guest session: no account, no password.
    public var username: String?

    public static let defaultPort = 445

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = SMBProfile.defaultPort,
        share: String,
        domain: String? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.share = share
        self.domain = domain
        self.username = username
    }

    /// No account at all. An empty `username` is an account whose name
    /// has not been typed yet — the setup screen's account mode — and is
    /// refused by `validationFailure` rather than silently sent as guest.
    public var isGuest: Bool { username == nil }

    /// The name the sidebar shows: the user's, or `share on host`.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(share) — \(host)" : trimmed
    }

    /// Whether `other` names the same filesystem: same host, port and
    /// share. A profile edited into another namespace becomes a new backend.
    public func namesSameShare(as other: SMBProfile) -> Bool {
        host.caseInsensitiveCompare(other.host) == .orderedSame
            && port == other.port
            && share.caseInsensitiveCompare(other.share) == .orderedSame
    }

    /// The backend ID this profile registers under.
    public var backendID: BackendID { BackendID("smb:" + id.uuidString) }

    /// The credential-store key of this profile's password.
    public var credentialKey: String { "wiki.qaq.fila.smb." + id.uuidString }

    /// The preference key of this backend's bookmarks and history.
    public var preferencesKey: String { "wiki.qaq.fila.smb." + id.uuidString + ".preferences" }

    /// Nil when `host` and `share` are usable; otherwise why not, for the
    /// setup screen. A share name may not contain a separator: `\\host\a\b`
    /// is a path inside share `a`, not a share.
    public var validationFailure: ValidationFailure? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return .hostMissing }
        if host.contains(where: { $0 == "/" || $0 == "\\" || $0 == " " }) { return .hostInvalid }
        guard (1 ... 65535).contains(port) else { return .portInvalid }
        if share.trimmingCharacters(in: .whitespaces).isEmpty { return .shareMissing }
        if share.contains(where: { $0 == "/" || $0 == "\\" }) { return .shareInvalid }
        if let username, username.trimmingCharacters(in: .whitespaces).isEmpty { return .usernameMissing }
        return nil
    }

    public enum ValidationFailure: Equatable, Sendable {
        case hostMissing
        case hostInvalid
        case portInvalid
        case shareMissing
        case shareInvalid
        case usernameMissing
    }
}

/// The saved profiles, as one record so an edit to one is a read-modify-
/// write of the list under one key. Versioned for a later layout change;
/// there is nothing older to migrate.
public struct SMBProfileList: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [SMBProfile]

    public init(profiles: [SMBProfile] = []) {
        version = Self.currentVersion
        self.profiles = profiles
    }

    /// The `DefaultStorage` key of the list in the process's defaults.
    public static let storageKey = "wiki.qaq.fila.smb.profiles"
}
