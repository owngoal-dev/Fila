import FilaBackendKit
@testable import FilaApplications
@testable import FilaClient
import Foundation
import Testing

@Suite("Applications backend")
@MainActor
struct ApplicationBackendTests {
    private func local() -> LocalFileBackend {
        LocalFileBackend(access: LocalFileService(), storage: MemoryStorage())
    }

    @Test("The legacy switches keep their keys, and only changed keys are written")
    func legacyKeys() throws {
        let name = "wiki.qaq.fila.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("identifier", forKey: "appSort")
        let storage = ApplicationPreferencesDefaults(defaults: defaults)
        var value = try #require(try storage.load())
        #expect(value.sort == .identifier && value.scope == .all)
        value.scope = .user
        try storage.save(value)
        #expect(defaults.string(forKey: "appScope") == "user")
        #expect(defaults.string(forKey: "appSort") == "identifier")
    }

    @Test("The feature is off until the handshake and off in a container")
    func gating() throws {
        let files = local()
        let backend = ApplicationBackend(local: files, storage: MemoryStorage())
        #expect(!backend.isEnabled)
        #expect(backend.sidebar().places.isEmpty)
        files.handshakeLanded(LocalHello(protocolVersion: 1, backend: .local(reach: .container)))
        #expect(!backend.isEnabled)
        files.handshakeLanded(LocalHello(protocolVersion: 1, backend: .local(reach: .user)))
        #expect(backend.isEnabled)
        #expect(backend.sidebar().places.map(\.kind) == [.root])
        #expect(backend.sidebar().places.first?.location == .root(of: .applications))
    }

    @Test("Scopes tell user apps from system apps by their bundle container")
    func scopes() {
        let user = InstalledApp(name: "A", bundleIdentifier: "a", bundlePath: "/var/containers/Bundle/Application/X/A.app", dataPath: nil)
        let system = InstalledApp(name: "B", bundleIdentifier: "b", bundlePath: "/Applications/B.app", dataPath: nil)
        #expect(AppScope.user.includes(user) && !AppScope.user.includes(system))
        #expect(AppScope.system.includes(system) && !AppScope.system.includes(user))
        #expect(AppScope.all.includes(user) && AppScope.all.includes(system))
        #expect(InstalledApp.name(" ", "\u{200E}", identifier: "com.apple.MediaRemoteUI") == "MediaRemoteUI")
        #expect(InstalledApp.name("Files", identifier: "x") == "Files")
    }

    @Test("Folder decorations name containers by their owner and the lookup walks every installed app")
    func decorations() async {
        let app = InstalledApp(
            name: "Fila",
            bundleIdentifier: "wiki.qaq.fila",
            bundlePath: "/private/var/containers/Bundle/Application/AAAA/Fila.app",
            dataPath: "/var/mobile/Containers/Data/Application/DDDD",
            groupPaths: ["group.wiki.qaq.fila": "/var/mobile/Containers/Shared/AppGroup/GGGG"]
        )
        let lookup = ApplicationFolderDecorations.lookup(for: [app])
        #expect(lookup("/var/containers/Bundle/Application/AAAA")?.name == "Fila")
        #expect(lookup("/private/var/mobile/Containers/Data/Application/DDDD")?.applicationIdentifier == "wiki.qaq.fila")
        #expect(lookup("/var/mobile/Containers/Shared/AppGroup/GGGG")?.name == "group.wiki.qaq.fila")
        #expect(lookup("/var/mobile/Containers/Shared/AppGroup/GGGG")?.detail == "Fila")
        #expect(lookup("/etc") == nil)

        // An unknown data container is named from its own metadata plist.
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataIdentifier": "com.example.other"], format: .xml, options: 0
        )
        let named = await ApplicationFolderDecorations.load(
            in: "/var/mobile/Containers/Data/Application",
            entries: [("DDDD", true), ("EEEE", true), ("file", false)],
            apps: [app]
        ) { path in path.hasPrefix("/var/mobile/Containers/Data/Application/EEEE/") ? plist : nil }
        #expect(named["DDDD"]?.name == "Fila")
        #expect(named["EEEE"]?.name == "other")
        #expect(named["EEEE"]?.detail == "com.example.other")
        #expect(named["file"] == nil)
        // Not a container root and no .app inside: nothing to decorate.
        let plain = await ApplicationFolderDecorations.load(in: "/etc", entries: [("x", true)], apps: [app]) { _ in nil }
        #expect(plain.isEmpty)
    }

    @Test("The catalogue is read once and dropped on a change hint or a new handshake")
    func caching() async {
        let files = local()
        let backend = ApplicationBackend(local: files, storage: MemoryStorage())
        // Off: nothing is read and nothing is kept.
        #expect(await backend.applications().isEmpty)
        #expect(backend.catalog == nil)
        // The handshake's republish arrives through a stream and drops the
        // cache as it lands; the root row is published only once it has,
        // so wait for that before counting reads.
        let sidebar = backend.sidebarUpdates()
        files.handshakeLanded(LocalHello(protocolVersion: 1, backend: .local(reach: .user)))
        // Bounded: a lost publish fails the test rather than hanging the suite.
        let landed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await snapshot in sidebar where !snapshot.places.isEmpty { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(landed)
        _ = await backend.applications()
        // `Task` is a handle: equal only when it is the same task.
        let first = backend.catalog
        #expect(first != nil)
        _ = await backend.applications()
        #expect(backend.catalog == first)
        // A visit publishes too — every folder the user uses does — and
        // must not cost the breadcrumb a second enumeration.
        if let path = try? ServicePath("/tmp") {
            try? files.recordVisit(path)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(backend.catalog == first)
        _ = await backend.applications(refresh: true)
        #expect(backend.catalog != nil && backend.catalog != first)
        backend.catalogChanged()
        #expect(backend.catalog == nil)
    }

    @Test("Only a container root or a folder holding an app bundle can carry decorations")
    func decorationPredicate() {
        #expect(ApplicationFolderDecorations.decorates("/private/var/containers/Bundle/Application", entries: []))
        #expect(ApplicationFolderDecorations.decorates("/var/mobile/Containers/Shared/AppGroup", entries: []))
        #expect(ApplicationFolderDecorations.decorates("/Applications", entries: [("Files.app", true)]))
        #expect(!ApplicationFolderDecorations.decorates("/Applications", entries: [("Files.app", false)]))
        #expect(!ApplicationFolderDecorations.decorates("/etc", entries: [("hosts", false), ("ssh", true)]))
    }

    @Test("The change stream hints at once and on every catalogue change")
    func changes() async {
        let backend = ApplicationBackend(local: local(), storage: MemoryStorage())
        var iterator = backend.changes().makeAsyncIterator()
        #expect(await iterator.next() != nil)
        backend.catalogChanged()
        #expect(await iterator.next() != nil)
    }
}
