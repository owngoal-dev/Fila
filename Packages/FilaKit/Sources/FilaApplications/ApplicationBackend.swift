import FilaBackendKit
import FilaClient
import FilaLog
import Foundation

/// The installed-applications catalogue as a backend, and the capability
/// the shell reaches apps through.
///
/// A catalogue, not a file backend: it owns its root, its preferences and
/// its sidebar row, and hands out apps rather than entries. Its I/O runs
/// over the local backend it is given — the container scan when
/// LaunchServices answers nothing, the metadata plists that name a
/// container — so a sandboxed process, which cannot see other apps at
/// all, gets no catalogue and offers no row.
@MainActor
public final class ApplicationBackend: Backend, ApplicationCapability {
    public let id = BackendID.applications
    public let root: BackendRoot
    public let local: LocalFileBackend

    public private(set) var preferences: ApplicationPreferences
    private let storage: any DefaultStorage<ApplicationPreferences>
    private var subscribers: [UUID: AsyncStream<BackendSidebar>.Continuation] = [:]
    private var changeSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var localUpdates: Task<Void, Never>?
    /// The catalogue as last read, shared by every caller until something
    /// says it changed. One read, not one per folder: every listing asks
    /// for decorations, the breadcrumb asks again, and enumerating
    /// LaunchServices costs tens of milliseconds each time — which was the
    /// tail of every directory opened.
    private(set) var catalog: Task<[InstalledApp], Never>?
    /// The backend the cached read was made under; a different answer from
    /// the handshake drops it.
    private var catalogBackend: LocalBackend?

    /// The framework bundle, for localized strings: the entry class is in
    /// the framework's own sources, so any class from this module resolves
    /// to it — and to the test bundle under `swift test`.
    nonisolated static var bundle: Bundle { Bundle(for: ApplicationBackend.self) }

    public init(local: LocalFileBackend, storage: any DefaultStorage<ApplicationPreferences>) {
        self.local = local
        self.storage = storage
        root = BackendRoot(
            location: .root(of: .applications),
            kind: .catalog,
            displayName: String(localized: "Applications", bundle: ApplicationBackend.bundle),
            artworkName: "application"
        )
        do {
            preferences = try storage.load() ?? ApplicationPreferences()
        } catch {
            preferences = ApplicationPreferences()
            FilaLog.error("application preferences unreadable, running on defaults: \(error)")
        }
        // The local backend republishes when the handshake lands, and
        // whether this catalogue can exist depends on that answer.
        localUpdates = Task { [weak self] in
            for await _ in local.sidebarUpdates() {
                guard let self, !Task.isCancelled else { return }
                // The stream carries every visit and favourite as well as
                // the handshake. Only a new backend is a new environment,
                // and only then is what was read under the old one not the
                // catalogue any more; a folder visit must not cost the
                // breadcrumb a LaunchServices read.
                let backend = local.hello?.backend
                if backend != catalogBackend {
                    catalogBackend = backend
                    catalog = nil
                }
                publish()
            }
        }
    }

    deinit {
        localUpdates?.cancel()
    }

    // MARK: - Capability

    /// The environment side: `LSApplicationWorkspace` and the container scan
    /// both read outside this app's container, so a sandboxed local backend
    /// can only ever answer with nothing. Nothing until the handshake has
    /// landed, and never a build flag.
    public var isEnabled: Bool {
        guard let backend = local.hello?.backend else { return false }
        if case .local(.container) = backend {
            return false
        }
        return true
    }

    public var sort: AppSort {
        get { preferences.sort }
        set { update(publishes: false) { $0.sort = newValue } }
    }

    public var scope: AppScope {
        get { preferences.scope }
        set { update(publishes: false) { $0.scope = newValue } }
    }

    /// Every installed app. Off means no LaunchServices call and no scan,
    /// for every caller — the page, the folder names, the recents, the
    /// links. On, the catalogue is read once and kept until
    /// `catalogChanged`, an install or a new handshake drops it; `refresh`
    /// reads again now, for the page whose pull-to-refresh means exactly
    /// that. Concurrent callers share the one read in flight.
    public func applications(refresh: Bool = false) async -> [InstalledApp] {
        guard isEnabled, let files = try? await local.fileService() else { return [] }
        if refresh {
            catalog = nil
        }
        let read = catalog ?? Task { await ApplicationCatalog.load(files: files) }
        catalog = read
        let apps = await read.value
        // No longer the read that is kept — dropped by an install landing,
        // or replaced by a pull — so what came back describes the moment
        // before that. Once more, joining whatever read is current rather
        // than starting one beside it.
        guard catalog != read, !Task.isCancelled else { return apps }
        let again = catalog ?? Task { await ApplicationCatalog.load(files: files) }
        catalog = again
        return await again.value
    }

    public func locate(bundleIdentifier: String) async -> ApplicationLocation? {
        let apps = await applications()
        guard let app = apps.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame })
        else { return nil }
        return ApplicationLocation(
            name: app.name, bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundlePath, dataPath: app.dataPath
        )
    }

    public func decorations(in directory: String, entries: [(name: String, isDirectory: Bool)]) async -> [String: FolderDecoration] {
        // The cheap question first: a folder that can carry no decoration
        // — nearly every folder — never asks for the catalogue.
        guard isEnabled, ApplicationFolderDecorations.decorates(directory, entries: entries) else { return [:] }
        let apps = await applications()
        guard !Task.isCancelled else { return [:] }
        let access = local.access
        return await ApplicationFolderDecorations.load(in: directory, entries: entries, apps: apps) { path in
            // Through the local layer — the file is root-owned — and small.
            guard let descriptor = try? await access.open(path, flags: O_RDONLY) else { return nil }
            return try? await Task.detached { try DescriptorIO.readAndClose(descriptor, limit: 64 * 1024) }.value
        }
    }

    public func decorationLookup() async -> (String) -> FolderDecoration? {
        guard isEnabled else { return { _ in nil } }
        return ApplicationFolderDecorations.lookup(for: await applications())
    }

    public func manifest(ofPackageAt url: URL) async throws -> PackageManifest {
        let manifest = try await IPAInstaller.manifest(ofIPAAt: url)
        return PackageManifest(bundleIdentifier: manifest.bundleID, displayName: manifest.displayName)
    }

    public func install(packageAt url: URL) async -> InstallOutcome {
        switch await IPAInstaller.install(ipaAt: url, packageType: "Developer") {
        case .installed:
            // The catalogue just grew; an open page lists again.
            catalogChanged()
            return .installed
        case let .failed(domain, code, message): return .failed(domain: domain, code: code, message: message)
        case let .unsupported(reason): return .unsupported(reason)
        case .timedOut: return .timedOut
        }
    }

    // MARK: - Changes

    /// Hints that the catalogue may have changed: the app came back to the
    /// foreground, an install finished. The framework feeds these. The
    /// cached read goes first, so the reload the hint starts reads afresh.
    public func catalogChanged() {
        catalog = nil
        for continuation in changeSubscribers.values {
            continuation.yield(())
        }
    }

    /// The initial hint at once, then one per `catalogChanged`.
    public func changes() -> AsyncStream<Void> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            changeSubscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeSubscribers[token] = nil }
            }
            continuation.yield(())
        }
    }

    // MARK: - Sidebar

    public func sidebarUpdates() -> AsyncStream<BackendSidebar> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[token] = nil }
            }
            continuation.yield(sidebar())
        }
    }

    /// The root, when the feature is on and the environment allows it. No
    /// favourites and no history: apps are not places.
    public func sidebar() -> BackendSidebar {
        guard isEnabled else { return .empty }
        return BackendSidebar(places: [SidebarRow(id: "root", location: root.location, path: nil, kind: .root)])
    }

    private func update(publishes: Bool = true, _ change: (inout ApplicationPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        do {
            try storage.save(next)
            preferences = next
            if publishes { publish() }
        } catch {
            FilaLog.error("application preferences not saved: \(error)")
        }
    }

    private func publish() {
        let snapshot = sidebar()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }
}
