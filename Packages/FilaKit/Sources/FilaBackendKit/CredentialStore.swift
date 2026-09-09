import Foundation

/// Where a backend keeps a secret: the password of a saved share, the
/// account of an FTP root.
///
/// Injected through the host, never reached for, and separate from
/// `DefaultStorage` on purpose: a preference record travels in plists and
/// logs and snapshots, and a password must not. A key is the backend's own
/// namespace — a profile ID, never a hostname — so two accounts on one
/// server never share a slot. Reading a key nothing was stored under is
/// nil, not an error; a store that cannot be reached throws.
public protocol CredentialStore: AnyObject, Sendable {
    func secret(for key: String) throws -> String?
    func setSecret(_ secret: String?, for key: String) throws
}

/// A store that forgets at the end of the process. For tests, and for a
/// process that has no keychain.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    /// Set to make every call fail, the way a locked keychain would.
    public var failure: Error?

    public init() {}

    public func secret(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return secrets[key]
    }

    public func setSecret(_ secret: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        secrets[key] = secret
    }

    public var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(secrets.keys)
    }
}
