import FilaBackendKit
import FilaLog
import FilaProtocol
import Foundation

/// The local filesystem presented as a backend.
///
/// One instance per launch, made by the local module: the full-filesystem
/// backend at `/` over whatever local access the launch resolved — the
/// privileged link, which chooses the daemon or in-process at the handshake,
/// or the in-process service on its own — and nothing else. `Backend`
/// identity is the module's, not the access's: the same root is the same
/// backend whichever side ends up answering, and its bookmarks are filed
/// under the same key either way.
///
/// The class has exactly one subclass, in this module. Everything that
/// reads or writes a file stays in `FilaFileOps` behind `access`; what the
/// subclass changes is where navigation starts and which access it is
/// allowed to hold.
///
/// Preferences are loaded once from the injected storage and owned here.
/// Every mutation saves the next value first and publishes a sidebar
/// snapshot only if the save succeeded, so what the user sees is what will
/// be there after a relaunch. A load that failed leaves the stored record
/// untouched: the backend runs on defaults and refuses to save over what it
/// could not read.
@MainActor
public class LocalFileBackend: FileBackend {
    public static let identifier = BackendID("local")

    /// What the app owns and the backend only points at.
    public struct Environment: Sendable {
        /// The shared Inbox, when the app has one. Offered as a place.
        public var inboxDirectory: String?
        /// The volume whose trash the unprivileged backend shows.
        public var trashVolume: String

        public init(inboxDirectory: String? = nil, trashVolume: String = "/private/var") {
            self.inboxDirectory = inboxDirectory
            self.trashVolume = trashVolume
        }
    }

    public let id: BackendID
    public let root: BackendRoot
    /// The absolute path `root` stands for. `/` for the full backend.
    public let rootPath: String
    /// The local file layer: descriptors, attributes, jobs. Consumers that
    /// need the local contract take this; everything else takes
    /// `fileService()`.
    public let access: any LocalFileAccess
    public let environment: Environment

    /// The loaded preferences: the one authority for bookmarks, history and
    /// listing options. Read freely; change through the methods below.
    public private(set) var preferences: LocalFilePreferences
    /// Why `preferences` are defaults rather than what was stored, when the
    /// store could not be read. Mutations throw this rather than overwrite.
    public private(set) var loadFailure: Error?

    /// The handshake's answer, once the app has it. Places depend on it —
    /// a bootstrap prefix exists only under a daemon — so the snapshot is
    /// republished when it lands.
    public private(set) var hello: LocalHello?

    private let storage: any DefaultStorage<LocalFilePreferences>
    private let defaultFavorites: [ServicePath]
    private var recordsVisits = true
    private var subscribers: [UUID: AsyncStream<BackendSidebar>.Continuation] = [:]
    private let observation = DirectoryObservation()
    private lazy var service = LocalFileServiceAdapter(access: access, rootPath: rootPath, observation: observation)

    /// Immutable inputs first, then shared behaviour: nothing here calls a
    /// hook a subclass may not be ready to answer. `rootPath` must be
    /// absolute; a trailing separator is dropped so paths join cleanly.
    public init(
        access: any LocalFileAccess,
        rootPath: String,
        displayName: String,
        symbolName: String,
        storage: any DefaultStorage<LocalFilePreferences>,
        environment: Environment,
        defaultFavorites: [ServicePath]
    ) {
        precondition(rootPath.hasPrefix("/"), "a local root is an absolute path")
        id = LocalFileBackend.identifier
        self.access = access
        var normalized = rootPath
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        self.rootPath = normalized
        self.storage = storage
        self.environment = environment
        self.defaultFavorites = defaultFavorites
        root = BackendRoot(
            location: .root(of: LocalFileBackend.identifier),
            kind: .filesystem,
            displayName: displayName,
            symbolName: symbolName
        )
        do {
            preferences = try storage.load() ?? LocalFilePreferences()
        } catch {
            preferences = LocalFilePreferences()
            loadFailure = error
            FilaLog.error("local preferences unreadable, running on defaults: \(error)")
        }
    }

    /// The full filesystem, from `/`, with the places a jailbroken device's
    /// user reaches for first as the default favourites.
    public convenience init(
        access: any LocalFileAccess,
        storage: any DefaultStorage<LocalFilePreferences>,
        environment: Environment = Environment()
    ) {
        self.init(
            access: access,
            rootPath: "/",
            displayName: "Local Files",
            symbolName: "internaldrive",
            storage: storage,
            environment: environment,
            defaultFavorites: LocalFileBackend.fullRootFavorites
        )
    }

    static let fullRootFavorites: [ServicePath] = [
        "var/mobile/Documents", "var/mobile/Library/Preferences", "etc",
    ].compactMap { try? ServicePath($0) }

    public func fileService() async throws -> any FileService {
        service
    }

    /// The absolute path for a location under this root — lexical, and safe
    /// because `ServicePath` admits no component that could climb out.
    public func absolutePath(_ path: ServicePath) -> String {
        service.absolutePath(path)
    }

    /// The location under this root for an absolute path, or nil when the
    /// path is not under it or is not a path at all.
    public func servicePath(forAbsolute absolute: String) -> ServicePath? {
        service.servicePath(forAbsolute: absolute)
    }

    /// Records that the app knows which side answers. Republishes places,
    /// which depend on it.
    public func handshakeLanded(_ hello: LocalHello) {
        guard self.hello?.backend != hello.backend else { return }
        self.hello = hello
        publish()
    }

    /// Tells every subscriber to these directories, and their descendants
    /// on screen, to list again. Called with what an operation touched.
    public func invalidate(_ absolutePaths: [String]) {
        observation.invalidate(absolutePaths)
    }

    /// Stops the directory polling while the app is not on screen, and
    /// restarts it — with a fresh listing for every subscriber — when it is.
    public func setObservationPaused(_ paused: Bool) {
        observation.setPaused(paused)
    }

    // MARK: - Favourites and history

    /// Absent means the user never touched them and the defaults apply;
    /// an empty list means they removed every one, and stays empty.
    public var favorites: [ServicePath] {
        preferences.files.favorites ?? defaultFavorites
    }

    public func isFavorite(_ path: ServicePath) -> Bool {
        favorites.contains(path)
    }

    public func setFavorite(_ path: ServicePath, included: Bool) throws {
        var list = favorites
        if included {
            guard !list.contains(path) else { return }
            list.append(path)
        } else {
            guard list.contains(path) else { return }
            list.removeAll { $0 == path }
        }
        try update { $0.files.favorites = list }
    }

    public var recents: [FileBackendPreferences.Visit] {
        preferences.files.recents
    }

    public func recordVisit(_ path: ServicePath) throws {
        guard recordsVisits else { return }
        try update { $0.files.noteVisit(path, at: Date()) }
    }

    /// A recent that is gone from disk is dropped, not left to fail again.
    public func forgetVisit(_ path: ServicePath) throws {
        guard recents.contains(where: { $0.path == path }) else { return }
        try update { $0.files.recents.removeAll { $0.path == path } }
    }

    public func setRecordsVisits(_ enabled: Bool) throws {
        recordsVisits = enabled
        // Turning it off clears what is already there. A switch that stops
        // adding but leaves the history behind has not done what its label
        // says, and here the history is the thing being objected to.
        if !enabled, !recents.isEmpty {
            try update { $0.files.recents = [] }
        }
    }

    // MARK: - Listing options

    /// The last visited directory, recorded whether or not history is: it
    /// is where the browser opens next time, not a trail.
    public var lastDirectory: ServicePath? {
        preferences.files.lastDirectory
    }

    public func setLastDirectory(_ path: ServicePath) throws {
        guard lastDirectory != path else { return }
        try update(publishes: false) { $0.files.lastDirectory = path }
    }

    public var sortKey: FileSortKey { preferences.files.sortKey }
    public var sortAscending: Bool { preferences.files.sortAscending }
    public var showsHidden: Bool { preferences.files.showsHidden }

    public func setSort(key: FileSortKey, ascending: Bool) throws {
        try update(publishes: false) {
            $0.files.sortKey = key
            $0.files.sortAscending = ascending
        }
    }

    public func setShowsHidden(_ shows: Bool) throws {
        try update(publishes: false) { $0.files.showsHidden = shows }
    }

    public func layout(for path: ServicePath) -> BrowserLayout {
        preferences.files.layout(for: path)
    }

    public func setLayout(_ layout: BrowserLayout, for path: ServicePath) throws {
        try update(publishes: false) { $0.files.setLayout(layout, for: path) }
    }

    // MARK: - Presets

    /// Every preset, in the user's order, hidden ones included.
    public var orderedPresets: [LocalPreset] {
        preferences.orderedPresets
    }

    public func isPresetEnabled(_ preset: LocalPreset) -> Bool {
        !preferences.hiddenPresets.contains(preset)
    }

    public func setPresetOrder(_ order: [LocalPreset]) throws {
        try update { $0.presetOrder = order }
    }

    public func setPreset(_ preset: LocalPreset, enabled: Bool) throws {
        try update {
            if enabled {
                $0.hiddenPresets.remove(preset)
            } else {
                $0.hiddenPresets.insert(preset)
            }
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

    /// The contribution as it stands: places from capabilities and preset
    /// choices, favourites and history from preferences.
    public func sidebar() -> BackendSidebar {
        BackendSidebar(
            places: places(),
            favorites: favorites.map { path in
                SidebarRow(id: "favorite:\(path)", location: location(path), path: path, kind: .favorite)
            },
            recents: recents.map { SidebarVisit(location: location($0.path), path: $0.path, visited: $0.visited) }
        )
    }

    /// The fixed places this root offers, in preset order, hidden presets
    /// left out. A preset that is not a local place — applications, music
    /// — is not here; the app slots those in by the same order.
    ///
    /// Places are checked to exist: the Mac development loop has no
    /// `/var/mobile`, and a place that does not exist sends the user to an
    /// empty folder that looks like the daemon being broken. The trash is
    /// the exception — root-owned 0700 under a daemon, invisible to the app
    /// and listed fine by the daemon.
    func places() -> [SidebarRow] {
        guard let backend = hello?.backend else { return [] }
        let available = availablePlaces(backend: backend)
        return orderedPresets.filter(isPresetEnabled).compactMap { available[$0] }
    }

    /// Whether this root has a place for `preset`, hidden or not: what a
    /// settings screen lists as switchable. Before the handshake every
    /// preset is possible; after it, exactly the places this root offers,
    /// which never include a catalogue preset.
    public func offersPreset(_ preset: LocalPreset) -> Bool {
        hello.map { availablePlaces(backend: $0.backend)[preset] != nil } ?? true
    }

    func availablePlaces(backend: LocalBackend) -> [LocalPreset: SidebarRow] {
        var rows: [LocalPreset: SidebarRow] = [:]
        func offer(_ preset: LocalPreset, _ absolute: String, _ kind: SidebarRow.Kind, checked: Bool = true) {
            guard let path = servicePath(forAbsolute: absolute) else { return }
            guard !checked || FileManager.default.fileExists(atPath: absolute) else { return }
            rows[preset] = SidebarRow(id: LocalFileBackend.placeID(preset), location: location(path), path: path, kind: kind)
        }
        if let inbox = environment.inboxDirectory {
            offer(.inbox, inbox, .inbox)
        }
        if case .local(.container) = backend {
            offer(.root, rootPath, .home, checked: false)
            return rows
        }
        offer(.root, rootPath, .root, checked: false)
        if case let .daemon(installRoot) = backend, !installRoot.isEmpty {
            offer(.bootstrap, installRoot, .bootstrap)
        }
        offer(.mobile, "/var/mobile", .home)
        offer(.pictures, "/var/mobile/Media/DCIM", .pictures)
        offer(.trash, trashDirectory(backend: backend), .trash, checked: false)
        return rows
    }

    /// The row id a preset's place carries, so the app can slot catalogue
    /// destinations into the same order without guessing at strings.
    public static func placeID(_ preset: LocalPreset) -> String {
        "\(preset)"
    }

    /// Matches the backend's trash: under a relocated bootstrap, otherwise
    /// under the configured volume.
    public func trashDirectory(backend: LocalBackend) -> String {
        LocalFileBackend.trashDirectory(backend: backend, volume: environment.trashVolume)
    }

    /// The trash for `volume` — the data volume for the sidebar, a mount
    /// point for an item being put back from it.
    public static func trashDirectory(backend: LocalBackend, volume: String) -> String {
        if case let .daemon(installRoot) = backend, !installRoot.isEmpty {
            return FilaTrash.directory(under: installRoot)
        }
        return FilaTrash.directory(under: volume)
    }

    private func location(_ path: ServicePath) -> BackendLocation {
        BackendLocation(backend: id, item: path.description)
    }

    /// Save first, publish only on success, and never over a record that
    /// could not be read.
    private func update(publishes: Bool = true, _ change: (inout LocalFilePreferences) -> Void) throws {
        if let loadFailure { throw loadFailure }
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        try storage.save(next)
        preferences = next
        if publishes {
            publish()
        }
    }

    private func publish() {
        let snapshot = sidebar()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }
}

/// The local backend a sandboxed process gets: the app's own Documents
/// directory, over in-process access, and no way to be handed anything else.
///
/// The type of `access` is the concrete in-process service on purpose. A
/// privileged link cannot be passed here, so a later reconnect cannot
/// promote this backend and privileged code cannot obtain daemon access
/// through it. The OS sandbox is what enforces the boundary on every
/// operation; this class only describes where navigation starts.
///
/// Its record is a separate scope from the full root's: an old absolute
/// favourite is never reinterpreted as a container path, and there are no
/// default favourites — the container is small enough to see whole.
@MainActor
public final class SandboxedLocalFileBackend: LocalFileBackend {
    /// `documents` defaults to the process's own Documents directory,
    /// resolved now rather than stored: a container's installation UUID
    /// is not a stable location.
    public init(
        access: LocalFileService = LocalFileService(),
        documents: URL? = nil,
        storage: any DefaultStorage<LocalFilePreferences>,
        environment: Environment = Environment()
    ) {
        super.init(
            access: access,
            rootPath: (documents ?? SandboxedLocalFileBackend.documentsDirectory()).path,
            displayName: "Documents",
            symbolName: "folder",
            storage: storage,
            environment: environment,
            defaultFavorites: []
        )
    }

    static func documentsDirectory() -> URL {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        return URL(fileURLWithPath: paths.first ?? NSHomeDirectory() + "/Documents", isDirectory: true)
    }
}
