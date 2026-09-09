import FilaBackendKit
@testable import FilaSMB
import Foundation
import Testing

@Suite("SMB profiles")
struct SMBProfileTests {
    @Test("Identity follows the profile ID, not the host")
    func identity() {
        let a = SMBProfile(name: "NAS", host: "nas.local", share: "media")
        var b = a
        b.name = "Renamed"
        b.username = "someone"
        #expect(a.backendID == b.backendID)
        #expect(a.credentialKey == b.credentialKey)
        #expect(a.namesSameShare(as: b))
        var c = a
        c.share = "Media"
        #expect(a.namesSameShare(as: c), "share names are case-insensitive on the wire")
        c.share = "other"
        #expect(!a.namesSameShare(as: c))
        c.share = a.share
        c.port = 4455
        #expect(!a.namesSameShare(as: c))
    }

    @Test("Validation names the field")
    func validation() {
        #expect(SMBProfile(name: "", host: "", share: "x").validationFailure == .hostMissing)
        #expect(SMBProfile(name: "", host: "a b", share: "x").validationFailure == .hostInvalid)
        #expect(SMBProfile(name: "", host: "h", port: 0, share: "x").validationFailure == .portInvalid)
        #expect(SMBProfile(name: "", host: "h", share: " ").validationFailure == .shareMissing)
        #expect(SMBProfile(name: "", host: "h", share: "a\\b").validationFailure == .shareInvalid)
        #expect(SMBProfile(name: "", host: "h", share: "x", username: " ").validationFailure == .usernameMissing)
        #expect(SMBProfile(name: "", host: "h", share: "x").validationFailure == nil)
        #expect(SMBProfile(name: "", host: "h", share: "x").isGuest)
        #expect(!SMBProfile(name: "", host: "h", share: "x", username: "").isGuest)
    }

    @Test("Display name falls back to share and host")
    func displayName() {
        #expect(SMBProfile(name: "  ", host: "h", share: "s").displayName == "s — h")
        #expect(SMBProfile(name: "Home NAS", host: "h", share: "s").displayName == "Home NAS")
    }

    @Test("The profile list round-trips without the password")
    func codable() throws {
        let list = SMBProfileList(profiles: [
            SMBProfile(name: "A", host: "a", share: "s", domain: "WORKGROUP", username: "u"),
            SMBProfile(name: "B", host: "b", port: 4455, share: "t"),
        ])
        let data = try JSONEncoder().encode(list)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("password"))
        let back = try JSONDecoder().decode(SMBProfileList.self, from: data)
        #expect(back == list)
        #expect(back.profiles[1].isGuest)
    }
}

@Suite("SMB wire paths")
struct SMBWirePathTests {
    @Test("Components are joined with backslashes; the root is empty")
    func join() throws {
        #expect(try SMBFileService.wirePath(.root) == "")
        #expect(try SMBFileService.wirePath(ServicePath("a/b c/ü")) == "a\\b c\\ü")
    }

    @Test("A component the protocol could read as a path is refused")
    func reserved() throws {
        for bad in ["a\\b", "a:b", "a*", "a?", "\"a\"", "<a>", "a|b"] {
            let path = try ServicePath(components: [bad])
            #expect(throws: SMBError.invalidName(bad)) { try SMBFileService.wirePath(path) }
        }
    }

    @Test("A zero FILETIME is no date")
    func fileTime() {
        #expect(SMBFileService.date(fileTime: 0) == nil)
        // 2024-01-01T00:00:00Z as a FILETIME.
        let raw: UInt64 = (1_704_067_200 + 11_644_473_600) * 10_000_000
        #expect(SMBFileService.date(fileTime: raw)?.timeIntervalSince1970 == 1_704_067_200)
        #expect(SMBFileService.date(Date(timeIntervalSince1970: -11_644_473_600)) == nil)
    }
}

@Suite("SMB backend")
@MainActor
struct SMBBackendTests {
    private func makeBackend(
        _ storage: MemoryStorage<FileBackendPreferences>? = nil
    ) -> (SMBBackend, MemoryStorage<FileBackendPreferences>, MemoryCredentialStore) {
        let storage = storage ?? MemoryStorage()
        let credentials = MemoryCredentialStore()
        let profile = SMBProfile(name: "NAS", host: "127.0.0.1", port: 1, share: "share", username: "u")
        let backend = SMBBackend(profile: profile, storage: storage, credentials: credentials)
        return (backend, storage, credentials)
    }

    @Test("A fresh backend offers its root and nothing else")
    func initialSidebar() {
        let (backend, _, _) = makeBackend()
        let sidebar = backend.sidebar()
        #expect(sidebar.places.map(\.kind) == [.root])
        #expect(sidebar.places[0].location == .root(of: backend.id))
        #expect(sidebar.favorites.isEmpty)
        #expect(sidebar.recents.isEmpty)
        #expect(backend.root.displayName == "NAS")
        #expect(backend.root.kind == .filesystem)
    }

    @Test("Favourites and visits persist and republish")
    func favoritesAndVisits() async throws {
        let (backend, storage, _) = makeBackend()
        var iterator = backend.sidebarUpdates().makeAsyncIterator()
        _ = await iterator.next()
        let photos = try ServicePath("Photos/2024")
        try backend.setFavorite(photos, included: true)
        let afterFavorite = await iterator.next()
        #expect(afterFavorite?.favorites.map(\.path) == [photos])
        #expect(afterFavorite?.favorites[0].kind == .favorite)
        #expect(storage.stored?.favorites == [photos])
        try backend.recordVisit(photos)
        let afterVisit = await iterator.next()
        #expect(afterVisit?.recents.map(\.path) == [photos])
        #expect(afterVisit?.recents[0].visited != nil)
        try backend.setFavorite(photos, included: false)
        let afterRemoval = await iterator.next()
        #expect(afterRemoval?.favorites.isEmpty == true)
        #expect(storage.stored?.favorites == [], "removing the last favourite stores empty, not absent")
    }

    @Test("Turning history off clears it and stops recording")
    func history() throws {
        let (backend, storage, _) = makeBackend()
        try backend.recordVisit(ServicePath("a"))
        try backend.setRecordsVisits(false)
        #expect(storage.stored?.recents.isEmpty == true)
        try backend.recordVisit(ServicePath("b"))
        #expect(backend.preferences.recents.isEmpty)
        try backend.setRecordsVisits(true)
        try backend.recordVisit(ServicePath("c"))
        #expect(backend.preferences.recents.map(\.path.description) == ["c"])
    }

    @Test("Unreadable preferences run on defaults and refuse to save over them")
    func loadFailure() throws {
        let storage = MemoryStorage<FileBackendPreferences>()
        storage.failure = CocoaError(.coderReadCorrupt)
        let (backend, _, _) = makeBackend(storage)
        #expect(backend.loadFailure != nil)
        #expect(throws: (any Error).self) { try backend.setFavorite(ServicePath("x"), included: true) }
        #expect(storage.saveCount == 0)
    }

    @Test("The service is built once and reads the password from the store at that moment")
    func serviceUsesStoredPassword() async throws {
        let (backend, _, credentials) = makeBackend()
        try credentials.setSecret("hunter2", for: backend.profile.credentialKey)
        let service = try await backend.fileService() as? SMBFileService
        #expect(service?.connection.configuration.password == "hunter2")
        #expect(service?.connection.configuration.username == "u")
        let again = try await backend.fileService() as? SMBFileService
        #expect(service === again)
        await backend.disconnect()
        let fresh = try await backend.fileService() as? SMBFileService
        #expect(fresh !== service)
    }

    @Test("A guest profile sends no account even with a stored secret")
    func guest() async throws {
        let credentials = MemoryCredentialStore()
        let profile = SMBProfile(name: "Guest", host: "127.0.0.1", port: 1, share: "public")
        try credentials.setSecret("stale", for: profile.credentialKey)
        let backend = SMBBackend(profile: profile, storage: MemoryStorage(), credentials: credentials)
        let service = try await backend.fileService() as? SMBFileService
        #expect(service?.connection.configuration.password == nil)
        #expect(service?.connection.configuration.isGuest == true)
    }

    @Test("A connection to a closed port fails as unreachable, not by hanging")
    func unreachable() async throws {
        let (backend, _, _) = makeBackend()
        let service = try await backend.fileService()
        let started = Date()
        do {
            _ = try await service.details(.root)
            Issue.record("a closed port answered")
        } catch let error as SMBError {
            switch error {
            case .connectionFailed, .timedOut, .disconnected: break
            default: Issue.record("unexpected \(error)")
            }
        }
        #expect(Date().timeIntervalSince(started) < 25)
    }
}
