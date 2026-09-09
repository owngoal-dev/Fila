import FilaBackendKit
import Foundation

/// The saved shares and their passwords: one list in the process's
/// defaults, one keychain item per profile.
///
/// The list is the authority on which backends exist at launch, and every
/// change to it goes through here so the record on disk and the secret in
/// the keychain move together. A password is written only when the caller
/// hands one over — an edit that leaves the field alone keeps what is
/// stored — and is removed with its profile.
@MainActor
public final class SMBProfileStore {
    public private(set) var profiles: [SMBProfile]
    /// Why the stored list could not be read, when it could not: the store
    /// runs empty and refuses to save over the record.
    public private(set) var loadFailure: Error?

    private let storage: any DefaultStorage<SMBProfileList>
    private let credentials: any CredentialStore

    public init(storage: any DefaultStorage<SMBProfileList>, credentials: any CredentialStore) {
        self.storage = storage
        self.credentials = credentials
        do {
            profiles = try storage.load()?.profiles ?? []
        } catch {
            profiles = []
            loadFailure = error
        }
    }

    public func profile(_ id: UUID) -> SMBProfile? {
        profiles.first { $0.id == id }
    }

    /// Adds or replaces `profile` by id, then stores `password` when one
    /// was given. `.some(nil)` clears the stored password — a share turned
    /// into a guest one — and `nil` leaves it alone. A keychain that
    /// refuses the password puts the record back as it was, so a share is
    /// never saved without the password it was given.
    public func save(_ profile: SMBProfile, password: String?? = nil) throws {
        if let loadFailure { throw loadFailure }
        let previous = profiles
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) {
            next[index] = profile
        } else {
            next.append(profile)
        }
        try storage.save(SMBProfileList(profiles: next))
        profiles = next
        if let password {
            do {
                try credentials.setSecret(password, for: profile.credentialKey)
            } catch {
                if (try? storage.save(SMBProfileList(profiles: previous))) != nil {
                    profiles = previous
                }
                throw error
            }
        }
    }

    /// Forgets `id`: the record first, then the password. A password that
    /// outlives a failed record removal is still reachable by its key; a
    /// record that outlives a failed password removal is not, which is why
    /// the order is this one.
    public func remove(_ id: UUID) throws {
        if let loadFailure { throw loadFailure }
        guard let profile = profile(id) else { return }
        let next = profiles.filter { $0.id != id }
        try storage.save(SMBProfileList(profiles: next))
        profiles = next
        try credentials.setSecret(nil, for: profile.credentialKey)
    }

    public func password(for profile: SMBProfile) throws -> String? {
        try credentials.secret(for: profile.credentialKey)
    }
}
