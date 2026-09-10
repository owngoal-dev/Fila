import FilaBackendKit
@testable import FilaClient
import Foundation
import Testing

/// Bookmarks, history and listing options as the local backend owns them,
/// against an in-memory store — and the same expectations against the
/// sandboxed subclass, whose only differences are its root and its empty
/// default favourites.
@Suite("Local backend preferences")
@MainActor
struct LocalFileBackendPreferencesTests {
    private struct Boom: Error {}

    private func full(_ storage: MemoryStorage<LocalFilePreferences>? = nil) -> LocalFileBackend {
        LocalFileBackend(access: LocalFileService(), storage: storage ?? MemoryStorage())
    }

    private func sandboxed(_ storage: MemoryStorage<LocalFilePreferences>? = nil) -> LocalFileBackend {
        SandboxedLocalFileBackend(
            documents: URL(fileURLWithPath: "/tmp/fila-sandbox", isDirectory: true),
            storage: storage ?? MemoryStorage()
        )
    }

    @Test("Absent favourites are the defaults; explicitly empty ones stay empty")
    func favoriteDefaults() throws {
        let storage = MemoryStorage<LocalFilePreferences>()
        let backend = full(storage)
        #expect(backend.favorites == LocalFileBackend.fullRootFavorites)
        #expect(sandboxed().favorites.isEmpty)

        for path in LocalFileBackend.fullRootFavorites {
            try backend.setFavorite(path, included: false)
        }
        #expect(backend.favorites.isEmpty)
        #expect(storage.stored?.files.favorites == [])
        // A relaunch reads the empty list, not the defaults.
        #expect(full(storage).favorites.isEmpty)
    }

    @Test("Favourites toggle, deduplicate and persist in the user's order")
    func favorites() throws {
        let storage = MemoryStorage<LocalFilePreferences>()
        let backend = sandboxed(storage)
        let a = try ServicePath("a"), b = try ServicePath("b")
        try backend.setFavorite(a, included: true)
        try backend.setFavorite(b, included: true)
        try backend.setFavorite(a, included: true)
        #expect(backend.favorites == [a, b])
        #expect(backend.isFavorite(a))
        #expect(storage.saveCount == 2)
        try backend.setFavorite(a, included: false)
        #expect(backend.favorites == [b])
        #expect(!backend.isFavorite(a))
    }

    @Test("Visits are dated, newest first, deduplicated and capped; undated history survives")
    func history() throws {
        let legacy = FileBackendPreferences.Visit(path: try ServicePath("old"), visited: nil)
        let storage = MemoryStorage(LocalFilePreferences(files: FileBackendPreferences(recents: [legacy])))
        let backend = full(storage)
        #expect(backend.recents == [legacy])

        let before = Date()
        try backend.recordVisit(try ServicePath("one"))
        try backend.recordVisit(try ServicePath("two"))
        try backend.recordVisit(try ServicePath("one"))
        #expect(backend.recents.map(\.path.description) == ["one", "two", "old"])
        #expect(backend.recents[0].visited! >= before)
        #expect(backend.recents[2].visited == nil)

        for index in 0 ..< FileBackendPreferences.recentLimit + 5 {
            try backend.recordVisit(try ServicePath("dir-\(index)"))
        }
        #expect(backend.recents.count == FileBackendPreferences.recentLimit)
        #expect(backend.recents.first?.path.description == "dir-\(FileBackendPreferences.recentLimit + 4)")

        try backend.forgetVisit(try ServicePath("dir-0"))
        #expect(!backend.recents.contains { $0.path.description == "dir-0" })
    }

    @Test("Turning history off clears it and stops recording; on records again")
    func historyPolicy() throws {
        let backend = full()
        try backend.recordVisit(try ServicePath("one"))
        try backend.setRecordsVisits(false)
        #expect(backend.recents.isEmpty)
        try backend.recordVisit(try ServicePath("two"))
        #expect(backend.recents.isEmpty)
        try backend.setRecordsVisits(true)
        try backend.recordVisit(try ServicePath("two"))
        #expect(backend.recents.map(\.path.description) == ["two"])
    }

    @Test("Listing options and per-folder layouts persist; the layout map drops wholesale at its cap")
    func listingOptions() throws {
        let storage = MemoryStorage<LocalFilePreferences>()
        let backend = full(storage)
        #expect(backend.sortKey == .name && backend.sortAscending && !backend.showsHidden)
        try backend.setSort(key: .size, ascending: false)
        try backend.setShowsHidden(true)
        try backend.setLastDirectory(try ServicePath("var/mobile"))
        let folder = try ServicePath("var")
        #expect(backend.layout(for: folder) == .list)
        try backend.setLayout(.grid, for: folder)
        #expect(backend.layout(for: folder) == .grid)
        #expect(backend.layout(for: .root) == .grid, "the default follows the last choice")

        let again = full(storage)
        #expect(again.sortKey == .size && !again.sortAscending && again.showsHidden)
        #expect(again.lastDirectory == (try ServicePath("var/mobile")))
        #expect(again.layout(for: folder) == .grid)

        // One folder is remembered already; fill up to the cap exactly.
        for index in 1 ..< FileBackendPreferences.folderLayoutLimit {
            try again.setLayout(.list, for: try ServicePath("f\(index)"))
        }
        #expect(again.preferences.files.folderLayouts.count == FileBackendPreferences.folderLayoutLimit)
        // A known folder changing its mind at the cap does not wipe the map.
        try again.setLayout(.grid, for: try ServicePath("f1"))
        #expect(again.preferences.files.folderLayouts.count == FileBackendPreferences.folderLayoutLimit)
        // A new one does.
        try again.setLayout(.grid, for: try ServicePath("overflow"))
        #expect(again.preferences.files.folderLayouts.count == 1)
    }

    @Test("Presets keep their order, append unplaced ones, and hide without forgetting")
    func presets() throws {
        let backend = full()
        #expect(backend.orderedPresets == LocalPreset.allCases)
        try backend.setPresetOrder([.trash, .root])
        #expect(backend.orderedPresets.prefix(2) == [.trash, .root])
        #expect(Set(backend.orderedPresets) == Set(LocalPreset.allCases))
        try backend.setPreset(.pictures, enabled: false)
        #expect(!backend.isPresetEnabled(.pictures))
        #expect(backend.orderedPresets.contains(.pictures))
        try backend.setPreset(.pictures, enabled: true)
        #expect(backend.isPresetEnabled(.pictures))
    }

    @Test("A store that failed to load is never written over")
    func loadFailure() throws {
        let storage = MemoryStorage(LocalFilePreferences(files: FileBackendPreferences(favorites: [try ServicePath("keep")])))
        storage.failure = Boom()
        let backend = full(storage)
        #expect(backend.loadFailure != nil)
        #expect(backend.favorites == LocalFileBackend.fullRootFavorites, "defaults, not what could not be read")
        storage.failure = nil
        #expect(throws: Boom.self) { try backend.setFavorite(try ServicePath("new"), included: true) }
        #expect(storage.stored?.files.favorites == [try ServicePath("keep")])
        #expect(storage.saveCount == 0)
    }

    @Test("A failed save keeps the prior state visible and reports the error")
    func saveFailure() throws {
        let storage = MemoryStorage<LocalFilePreferences>()
        let backend = full(storage)
        storage.failure = Boom()
        #expect(throws: Boom.self) { try backend.setFavorite(try ServicePath("new"), included: true) }
        #expect(backend.favorites == LocalFileBackend.fullRootFavorites)
    }

    /// Collects a sidebar stream from a task that is never cancelled.
    private final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [BackendSidebar] = []
        private var task: Task<Void, Never>?
        var all: [BackendSidebar] { lock.withLock { received } }
        var latest: BackendSidebar? { all.last }

        init(_ stream: AsyncStream<BackendSidebar>) {
            task = Task { [weak self] in
                for await snapshot in stream {
                    guard let self else { return }
                    lock.withLock { self.received.append(snapshot) }
                }
            }
        }

        func latest(where condition: @escaping (BackendSidebar) -> Bool, within seconds: Double = 1) async -> BackendSidebar? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let latest, condition(latest) { return latest }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return nil
        }

        deinit { task?.cancel() }
    }

    @Test("Sidebar streams start with the current snapshot, replace it on change, and each subscriber sees the latest")
    func sidebarStream() async throws {
        let backend = sandboxed()
        let first = Snapshots(backend.sidebarUpdates())
        var second = backend.sidebarUpdates().makeAsyncIterator()
        let initial = await first.latest(where: { _ in true })
        #expect(initial?.favorites.isEmpty == true)
        #expect(initial?.places.isEmpty == true, "no handshake yet, so no places")

        try backend.setFavorite(try ServicePath("a"), included: true)
        try backend.setFavorite(try ServicePath("b"), included: true)
        let latest = await first.latest(where: { $0.favorites.count == 2 })
        #expect(latest?.favorites.map(\.path?.description) == ["a", "b"])
        #expect(latest?.favorites.first?.kind == .favorite)
        #expect(latest?.favorites.first?.location == BackendLocation(backend: backend.id, item: "a"))
        // The second subscriber was never read; it still holds only the
        // newest snapshot.
        let other = await second.next()
        #expect(other?.favorites.count == 2)

        try backend.recordVisit(try ServicePath("a"))
        let visited = await first.latest(where: { !$0.recents.isEmpty })
        #expect(visited?.recents.map(\.path.description) == ["a"])

        // Options do not republish the sidebar: nothing on it changed.
        let count = first.all.count
        try backend.setShowsHidden(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(first.all.count == count)

        let handshake = LocalHello(protocolVersion: 1, backend: .local(reach: .container))
        backend.handshakeLanded(handshake)
        let placed = await first.latest(where: { !$0.places.isEmpty })
        #expect(placed?.places.map(\.kind) == [.home])
        #expect(placed?.places.first?.id == LocalFileBackend.placeID(.root))
    }

    @Test("Places follow the handshake: bootstrap only under a relocated daemon, trash always, presets ordered and hidden")
    func places() throws {
        let scratch = LocalScratch()
        scratch.directory("var/mobile/Media/DCIM")
        scratch.directory("jb")
        let inbox = scratch.directory("inbox")
        let backend = LocalFileBackend(
            access: LocalFileService(),
            rootPath: scratch.root,
            displayName: "Scratch",
            artworkName: "folder",
            storage: MemoryStorage(),
            environment: .init(inboxDirectory: inbox, trashVolume: scratch.root),
            defaultFavorites: []
        )
        // The unprivileged full root: no bootstrap row, trash on the volume.
        var rows = backend.availablePlaces(backend: .local(reach: .user))
        #expect(rows[.root]?.kind == .root)
        #expect(rows[.bootstrap] == nil)
        #expect(rows[.inbox]?.path?.description == "inbox")
        #expect(rows[.mobile] == nil, "/var/mobile is outside this root")
        #expect(rows[.trash]?.kind == .trash)
        #expect(backend.trashDirectory(backend: .local(reach: .user)).hasPrefix(scratch.root))

        // A relocated daemon: the bootstrap row and the trash under it.
        rows = backend.availablePlaces(backend: .daemon(installRoot: scratch.path("jb")))
        #expect(rows[.bootstrap]?.path?.description == "jb")
        #expect(backend.trashDirectory(backend: .daemon(installRoot: scratch.path("jb"))).hasPrefix(scratch.path("jb")))

        // A sandboxed process: home and inbox only.
        rows = backend.availablePlaces(backend: .local(reach: .container))
        #expect(Set(rows.keys) == [.root, .inbox])
        #expect(rows[.root]?.kind == .home)

        backend.handshakeLanded(LocalHello(protocolVersion: 1, backend: .local(reach: .user)))
        try backend.setPresetOrder([.trash, .inbox, .root])
        try backend.setPreset(.inbox, enabled: false)
        #expect(backend.sidebar().places.map(\.id) == [LocalFileBackend.placeID(.trash), LocalFileBackend.placeID(.root)])
    }
}
