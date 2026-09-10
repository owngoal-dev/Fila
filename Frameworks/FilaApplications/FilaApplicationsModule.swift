import FilaCore
import Foundation
import UIKit

/// The applications module: the installed-app catalogue, its screens, and
/// the artwork and folder decorations the rest of the app borrows.
///
/// It needs the local backend — the container scan and the metadata reads
/// go through it — so the factory resolves after every module registered
/// and produces nothing when no local backend exists.
@objc(FilaApplicationsModule)
public final class FilaApplicationsModule: NSObject, BackendModule {
    private var backend: ApplicationBackend?

    public required override init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        let host = registration.host
        try registration.provide((any ApplicationArtwork).self, ApplicationArtworkCache.shared as any ApplicationArtwork)
        // The capability is resolved through the backend once it exists;
        // registering a proxy keeps the provider set complete before the
        // factory runs.
        let proxy = ApplicationCapabilityProxy()
        try registration.provide((any ApplicationCapability).self, proxy as any ApplicationCapability)
        try registration.route(.applications) { [weak self] location in
            guard location.isRoot, let backend = self?.backend else { return nil }
            return ApplicationListViewController(backend: backend)
        }
        registration.backends { [weak self] resolver in
            guard let local = resolver.backend(LocalFileBackend.identifier) as? LocalFileBackend else {
                host.warn("applications: no local backend to read through")
                return []
            }
            let backend = ApplicationBackend(local: local, storage: ApplicationPreferencesDefaults(defaults: host.defaults))
            proxy.backend = backend
            self?.backend = backend
            return [backend]
        }
    }
}

/// Stands in for the backend in the provider set, which is filled before
/// any backend is made. Every call forwards; before the factory ran the
/// feature reads as off.
@MainActor
final class ApplicationCapabilityProxy: ApplicationCapability {
    var backend: ApplicationBackend?

    var isEnabled: Bool { backend?.isEnabled ?? false }

    func locate(bundleIdentifier: String) async -> ApplicationLocation? {
        await backend?.locate(bundleIdentifier: bundleIdentifier)
    }

    func decorations(in directory: String, entries: [(name: String, isDirectory: Bool)]) async -> [String: FolderDecoration] {
        await backend?.decorations(in: directory, entries: entries) ?? [:]
    }

    func decorationLookup() async -> (String) -> FolderDecoration? {
        await backend?.decorationLookup() ?? { _ in nil }
    }

    func manifest(ofPackageAt url: URL) async throws -> PackageManifest {
        guard let backend else { throw ApplicationsUnavailable() }
        return try await backend.manifest(ofPackageAt: url)
    }

    func install(packageAt url: URL) async -> InstallOutcome {
        await backend?.install(packageAt: url) ?? .unsupported("applications backend not available")
    }

    struct ApplicationsUnavailable: Error {}
}
