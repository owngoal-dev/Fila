import FilaCore
import Foundation
import UIKit

/// The WebDAV module: one backend per saved server — Alist, Nextcloud, a
/// NAS — the screen that browses it, and the setup that adds, edits and
/// removes servers. The same shape as the SMB module, over HTTP.
///
/// Saved servers are read once at registration and become backends through
/// the factory, so a launch with three servers has three sidebar roots
/// before any window exists and without touching the network. A server
/// saved later in the session is added to the host at once and appears
/// the same way; a removed one is retired with its bookmarks and password.
///
/// The class is not main-actor isolated — the discovery contract's `init`
/// is not — but everything it holds is: registration, the factory and the
/// setup closures all run there.
@objc(FilaWebDAVModule)
public final class FilaWebDAVModule: NSObject, BackendModule {
    @MainActor private var host: (any BackendHost)?
    @MainActor private var store: WebDAVProfileStore?
    @MainActor private var backends: [BackendID: WebDAVBackend] = [:]

    override public required init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        let host = registration.host
        self.host = host
        let store = WebDAVProfileStore(
            storage: UserDefaultsStorage<WebDAVProfileList>(defaults: host.defaults, key: WebDAVProfileList.storageKey),
            credentials: host.credentials,
        )
        self.store = store
        if let failure = store.loadFailure {
            // Saved servers that cannot be read are not shown and not
            // overwritten; the next launch tries again.
            throw BackendModuleError.registration("saved WebDAV servers unreadable: \(failure)")
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
                let backend = makeBackend(profile, host: resolver.host)
                backends[backend.id] = backend
                made.append(backend)
            }
            return made
        }
        registration.connectionSetup(
            title: String(localized: "WebDAV Server", bundle: WebDAVBackend.bundle),
            listTitle: String(localized: "WebDAV Servers", bundle: WebDAVBackend.bundle),
            owns: { [weak self] id in self?.backends[id] != nil },
            makeScreen: { [weak self] id in
                guard let self else { return nil }
                let existing = id.flatMap { self.backends[$0] }
                return UINavigationController(rootViewController: WebDAVConnectionViewController(module: self, existing: existing))
            },
            remove: { [weak self] id in try self?.remove(id) },
        )
    }

    // MARK: - Backends

    @MainActor
    private func makeBackend(_ profile: WebDAVProfile, host: any BackendHost) -> WebDAVBackend {
        WebDAVBackend(
            profile: profile,
            storage: UserDefaultsStorage<FileBackendPreferences>(defaults: host.defaults, key: profile.preferencesKey),
            credentials: host.credentials,
        )
    }

    @MainActor
    private func screen(for location: BackendLocation) -> AnyObject? {
        guard let backend = backends[location.backend], let path = try? ServicePath(location.item) else { return nil }
        return FileServiceBrowserViewController(backend: backend, path: path)
    }

    /// The backend for `profile` as saved by the setup screen. An edit
    /// that kept the address keeps the backend and its bookmarks; one that
    /// named another retires the old backend and registers a new
    /// one under a new identity. `password` follows `WebDAVProfileStore.save`.
    /// Returns the backend the profile now lives in.
    @MainActor
    @discardableResult
    func save(_ profile: WebDAVProfile, password: String??, replacing previous: WebDAVBackend?) async throws -> WebDAVBackend {
        guard let host, let store else { throw ModuleNotRegistered() }
        if let previous, previous.profile.id == profile.id {
            try store.save(profile, password: password)
            await previous.update(profile: profile)
            return previous
        }
        // The new identity is written and live before the old one goes:
        // a store that refuses the write leaves the user with the server
        // they had, never with neither.
        try store.save(profile, password: password)
        let backend = makeBackend(profile, host: host)
        do {
            try host.addBackend(backend) { [weak self] location in self?.screen(for: location) }
        } catch {
            // Not live, so not saved: the record and its password go again,
            // or the next Save would add a second copy beside it.
            try? store.remove(profile.id)
            throw error
        }
        backends[backend.id] = backend
        if let previous {
            // The save already happened: the new entry is live. An old one
            // that will not go stays in the sidebar for the user to remove,
            // rather than turning a saved edit into a reported failure that
            // invites saving it a second time.
            do {
                try remove(previous.id)
            } catch {
                FilaLog.warning("webdav: the entry \(previous.id) was replaced but could not be removed: \(error)")
            }
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
        backend.retire()
    }

    @MainActor
    var profileStore: WebDAVProfileStore? {
        store
    }

    struct ModuleNotRegistered: Error {}
}
