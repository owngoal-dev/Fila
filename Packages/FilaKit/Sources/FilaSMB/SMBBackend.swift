import FilaBackendKit
import FilaLog
import Foundation

/// One saved SMB share as a file backend.
///
/// The backend outlives any session: it exists from the moment the profile
/// is saved, offers its bookmarks and history while the server is off, and
/// connects only when the first I/O is asked for. Its identity is the
/// profile's, so a renamed share or a changed password keeps its bookmarks
/// and a share pointed at another server does not — see `SMBProfile`.
@MainActor
public final class SMBBackend: FileBackend {
    /// The bundle the module's strings live in — the framework's when this
    /// is compiled into one, the package's otherwise.
    public nonisolated static var bundle: Bundle { Bundle(for: SMBBackend.self) }

    public let id: BackendID
    /// Follows the profile's name; the identity underneath does not move.
    public var root: BackendRoot {
        BackendRoot(
            location: .root(of: id),
            kind: .filesystem,
            displayName: profile.displayName,
            artworkName: "shared-folder",
            detail: profile.address
        )
    }

    public private(set) var profile: SMBProfile
    public private(set) var preferences: FileBackendPreferences
    /// Why the stored preferences could not be read, when they could not:
    /// the backend runs on defaults and refuses to save over the record.
    public private(set) var loadFailure: Error?

    private let storage: any DefaultStorage<FileBackendPreferences>
    private let credentials: any CredentialStore
    private let pollInterval: TimeInterval
    private var recordsVisits = true
    private var subscribers: [UUID: AsyncStream<BackendSidebar>.Continuation] = [:]
    private var service: SMBFileService?

    public init(
        profile: SMBProfile,
        storage: any DefaultStorage<FileBackendPreferences>,
        credentials: any CredentialStore,
        pollInterval: TimeInterval = RemoteDirectoryObservation.pollInterval
    ) {
        self.profile = profile
        self.storage = storage
        self.credentials = credentials
        self.pollInterval = pollInterval
        id = profile.backendID
        do {
            preferences = try storage.load() ?? FileBackendPreferences()
        } catch {
            preferences = FileBackendPreferences()
            loadFailure = error
            FilaLog.error("smb: preferences for \(profile.backendID) unreadable, running on defaults: \(error)")
        }
    }

    /// The share's own name, for rows and titles that want it.
    public var shareName: String { profile.share }

    // MARK: - Service

    /// The I/O session, built on first ask with the password as stored now.
    /// A missing password is not an error here: a guest share has none, and
    /// a server that wants one says so when the session is set up.
    public func fileService() async throws -> any FileService {
        if let service { return service }
        let password = profile.isGuest ? nil : try credentials.secret(for: profile.credentialKey)
        let service = SMBFileService(profile: profile, password: password, pollInterval: pollInterval)
        self.service = service
        return service
    }

    /// Retires the current session and its subscriptions: what the module
    /// does before a credential change takes effect and when the profile
    /// is removed. The next `fileService` connects afresh.
    public func disconnect() async {
        guard let service else { return }
        self.service = nil
        await service.disconnect()
    }

    /// Adopts an edit that kept this backend's identity — a new name, a
    /// new account — and retires the session so the next one uses it.
    public func update(profile: SMBProfile) async {
        precondition(profile.id == self.profile.id, "a profile naming another share is another backend")
        self.profile = profile
        await disconnect()
        publish()
    }

    public func setObservationPaused(_ paused: Bool) {
        service?.observation.setPaused(paused)
    }

    /// Nothing to tell when no session was ever opened: no screen is
    /// subscribed to a share that was never connected.
    public func invalidate(_ directories: [ServicePath]) {
        service?.invalidate(directories)
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

    public func sidebar() -> BackendSidebar {
        let rootRow = SidebarRow(id: "root", location: location(.root), path: .root, kind: .root)
        let favorites = (preferences.favorites ?? []).map { path in
            SidebarRow(id: path.description, location: location(path), path: path, kind: .favorite)
        }
        let recents = preferences.recents.map { visit in
            SidebarVisit(location: location(visit.path), path: visit.path, visited: visit.visited)
        }
        return BackendSidebar(places: [rootRow], favorites: favorites, recents: recents)
    }

    public func isFavorite(_ path: ServicePath) -> Bool {
        preferences.favorites?.contains(path) ?? false
    }

    public func setFavorite(_ path: ServicePath, included: Bool) throws {
        try update { preferences in
            var list = preferences.favorites ?? []
            list.removeAll { $0 == path }
            if included { list.append(path) }
            preferences.favorites = list
        }
    }

    public func recordVisit(_ path: ServicePath) throws {
        guard recordsVisits else { return }
        try update { $0.noteVisit(path, at: Date()) }
    }

    public func forgetVisit(_ path: ServicePath) throws {
        try update { $0.recents.removeAll { $0.path == path } }
    }

    public func setRecordsVisits(_ enabled: Bool) throws {
        recordsVisits = enabled
        guard !enabled else { return }
        try update { $0.recents = [] }
    }

    /// The directory a tab or the root screen last showed, for the next
    /// launch's restoration. Not a sidebar change.
    public func setLastDirectory(_ path: ServicePath?) throws {
        try update(publishes: false) { $0.lastDirectory = path }
    }

    private func location(_ path: ServicePath) -> BackendLocation {
        BackendLocation(backend: id, item: path.description)
    }

    private func update(publishes: Bool = true, _ change: (inout FileBackendPreferences) -> Void) throws {
        if let loadFailure { throw loadFailure }
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        try storage.save(next)
        preferences = next
        if publishes { publish() }
    }

    private func publish() {
        let snapshot = sidebar()
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }
}
