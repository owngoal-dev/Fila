import FilaBackendKit
@testable import FilaClient
import Foundation
import Testing

/// The full root's storage keeps the keys and shapes the app has always
/// written, so an upgrade loses nothing and a downgrade still finds its list.
@Suite("Legacy local preference keys")
@MainActor
struct LocalPreferencesDefaultsTests {
    /// A suite of its own per test, removed again so a run leaves no plist
    /// behind.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "wiki.qaq.fila.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("Nothing stored loads as nothing chosen, not as empty")
    func empty() throws {
        try withDefaults { defaults in
            let loaded = try LocalPreferencesDefaults(defaults: defaults).load()
            #expect(loaded?.files.favorites == nil)
            #expect(loaded?.files.recents.isEmpty == true)
            #expect(loaded?.files.lastDirectory == nil)
            #expect(loaded?.files.sortKey == .name)
            #expect(loaded?.presetOrder.isEmpty == true)
        }
    }

    @Test("An existing installation's keys read back as they were written")
    func legacyRead() throws {
        try withDefaults { defaults in
        defaults.set(["/var/mobile/Documents", "/etc"], forKey: "favorites")
        defaults.set(["/var/mobile", "/var/mobile/file.txt", "/"], forKey: "recents")
        defaults.set(["/var/mobile/file.txt"], forKey: "recentFiles")
        defaults.set("/var/mobile", forKey: "lastDirectory")
        defaults.set("size", forKey: "sortKey")
        defaults.set(false, forKey: "sortAscending")
        defaults.set(true, forKey: "showsHidden")
        defaults.set("grid", forKey: "layout")
        defaults.set(["/etc": "list", "bad/../path": "grid"], forKey: "folderLayouts")
        defaults.set([7, 0, 99], forKey: "presetOrder")
        defaults.set([4], forKey: "hiddenPresets")

        let loaded = try #require(try LocalPreferencesDefaults(defaults: defaults).load())
        #expect(loaded.files.favorites?.map(\.description) == ["var/mobile/Documents", "etc"])
        #expect(loaded.files.recents.map(\.path.description) == ["var/mobile", ""], "files are filtered out, the root survives")
        #expect(loaded.files.recents.allSatisfy { $0.visited == nil }, "no invented times")
        #expect(loaded.files.lastDirectory?.description == "var/mobile")
        #expect(loaded.files.sortKey == .size && !loaded.files.sortAscending && loaded.files.showsHidden)
        #expect(loaded.files.layout == .grid)
        #expect(loaded.files.folderLayouts == [try ServicePath("etc"): .list], "a string that is not a path is dropped")
        #expect(loaded.presetOrder == [.trash, .root], "an unknown preset is dropped")
        #expect(loaded.hiddenPresets == [.pictures])
        }
    }

    @Test("Saving writes the legacy keys, dated visits beside the path list, and round-trips")
    func roundTrip() throws {
        try withDefaults { defaults in
        let storage = LocalPreferencesDefaults(defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var value = LocalFilePreferences(
            files: FileBackendPreferences(
                favorites: [],
                recents: [
                    .init(path: try ServicePath("var/mobile"), visited: when),
                    .init(path: try ServicePath("etc"), visited: nil),
                ],
                lastDirectory: try ServicePath("var"),
                sortKey: .date,
                sortAscending: false,
                showsHidden: true,
                layout: .grid,
                folderLayouts: [try ServicePath("var"): .list]
            ),
            presetOrder: [.mobile, .root],
            hiddenPresets: [.trash, .inbox]
        )
        try storage.save(value)
        #expect(defaults.stringArray(forKey: "favorites") == [])
        #expect(defaults.stringArray(forKey: "recents") == ["/var/mobile", "/etc"])
        #expect(defaults.dictionary(forKey: "recentVisits") as? [String: Double] == ["/var/mobile": when.timeIntervalSince1970])
        #expect(defaults.string(forKey: "lastDirectory") == "/var")
        #expect(defaults.dictionary(forKey: "folderLayouts") as? [String: String] == ["/var": "list"])
        #expect(defaults.array(forKey: "presetOrder") as? [Int] == [3, 0])
        #expect(defaults.array(forKey: "hiddenPresets") as? [Int] == [6, 7])
        #expect(try storage.load() == value)

        value.files.favorites = nil
        try storage.save(value)
        #expect(defaults.object(forKey: "favorites") == nil, "absent stays absent")
        #expect(try storage.load()?.files.favorites == nil)
        }
    }

    @Test("A save touches only the keys whose value changed, so unknown values elsewhere survive")
    func partialWrites() throws {
        try withDefaults { defaults in
            // A newer build hid a preset this build does not know.
            defaults.set([4, 99], forKey: "hiddenPresets")
            defaults.set(["/var//odd"], forKey: "favorites")
            let storage = LocalPreferencesDefaults(defaults: defaults)
            var value = try #require(try storage.load())
            value.files.lastDirectory = try ServicePath("var")
            try storage.save(value)
            #expect(defaults.array(forKey: "hiddenPresets") as? [Int] == [4, 99])
            #expect(defaults.stringArray(forKey: "favorites") == ["/var//odd"])
            #expect(defaults.string(forKey: "lastDirectory") == "/var")

            // Nothing was loaded first: everything is written.
            let fresh = LocalPreferencesDefaults(defaults: defaults)
            try fresh.save(LocalFilePreferences(hiddenPresets: [.trash]))
            #expect(defaults.array(forKey: "hiddenPresets") as? [Int] == [7])
        }
    }
}
