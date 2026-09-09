import FilaCore
import Foundation
import UIKit

/// The SMB module: one backend per saved share, the screen that browses
/// it, and the setup that adds, edits and removes shares.
///
/// Saved shares are read once at registration and become backends through
/// the factory, so a launch with three shares has three sidebar roots
/// before any window exists and without touching the network. A share
/// saved later in the session is added to the host at once and appears
/// the same way; a removed one is retired with its bookmarks and password.
///
/// The class is not main-actor isolated — the discovery contract's `init`
/// is not — but everything it holds is: registration, the factory and the
/// setup closures all run there.
@objc(FilaSMBModule)
public final class FilaSMBModule: NSObject, BackendModule {
    @MainActor private var host: (any BackendHost)?
    @MainActor private var store: SMBProfileStore?
    @MainActor private var backends: [BackendID: SMBBackend] = [:]

    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        let host = registration.host
        self.host = host
        let store = SMBProfileStore(
            storage: UserDefaultsStorage<SMBProfileList>(defaults: host.defaults, key: SMBProfileList.storageKey),
            credentials: host.credentials
        )
        self.store = store
        if let failure = store.loadFailure {
            // Saved shares that cannot be read are not shown and not
            // overwritten; the next launch tries again.
            throw BackendModuleError.registration("saved SMB shares unreadable: \(failure)")
        }
        for profile in store.profiles {
            try registration.route(profile.backendID) { [weak self] location in
                self?.screen(for: location)
            }
        }
        registration.backends { [weak self] resolver in
            guard let self else { return [] }
            var made: [any Backend] = []
            for profile in store.profiles {
                let backend = self.makeBackend(profile, host: resolver.host)
                self.backends[backend.id] = backend
                made.append(backend)
            }
            return made
        }
        registration.connectionSetup(
            title: String(localized: "SMB Share", bundle: SMBBackend.bundle),
            listTitle: String(localized: "SMB Shares", bundle: SMBBackend.bundle),
            owns: { [weak self] id in self?.backends[id] != nil },
            makeScreen: { [weak self] id in
                guard let self else { return nil }
                let existing = id.flatMap { self.backends[$0] }
                return UINavigationController(rootViewController: SMBConnectionViewController(module: self, existing: existing))
            },
            remove: { [weak self] id in try self?.remove(id) }
        )
    }

    // MARK: - Backends

    @MainActor
    private func makeBackend(_ profile: SMBProfile, host: any BackendHost) -> SMBBackend {
        SMBBackend(
            profile: profile,
            storage: UserDefaultsStorage<FileBackendPreferences>(defaults: host.defaults, key: profile.preferencesKey),
            credentials: host.credentials
        )
    }

    @MainActor
    private func screen(for location: BackendLocation) -> AnyObject? {
        guard let backend = backends[location.backend], let path = try? ServicePath(location.item) else { return nil }
        return FileServiceBrowserViewController(backend: backend, path: path)
    }

    /// The backend for `profile` as saved by the setup screen. An edit
    /// that kept the share keeps the backend and its bookmarks; one that
    /// named another share retires the old backend and registers a new
    /// one under a new identity. `password` follows `SMBProfileStore.save`.
    /// Returns the backend the profile now lives in.
    @MainActor
    @discardableResult
    func save(_ profile: SMBProfile, password: String??, replacing previous: SMBBackend?) async throws -> SMBBackend {
        guard let host, let store else { throw ModuleNotRegistered() }
        if let previous, previous.profile.id == profile.id {
            try store.save(profile, password: password)
            await previous.update(profile: profile)
            return previous
        }
        // The new identity is written and live before the old one goes:
        // a store that refuses the write leaves the user with the share
        // they had, never with neither.
        try store.save(profile, password: password)
        let backend = makeBackend(profile, host: host)
        try host.addBackend(backend) { [weak self] location in self?.screen(for: location) }
        backends[backend.id] = backend
        if let previous {
            try remove(previous.id)
        }
        return backend
    }

    /// Forgets the backend `id`: registration, session, saved record and
    /// password. Bookmarks go with the record.
    @MainActor
    func remove(_ id: BackendID) throws {
        guard let host, let store, let backend = backends[id] else { return }
        try store.remove(backend.profile.id)
        // Its preference record goes too; the key is the profile's and no
        // other backend can be given it.
        host.defaults.removeObject(forKey: backend.profile.preferencesKey)
        backends[id] = nil
        host.removeBackend(id)
        Task { await backend.disconnect() }
    }

    @MainActor
    var profileStore: SMBProfileStore? { store }

    struct ModuleNotRegistered: Error {}
}
