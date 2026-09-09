import FilaBackendKit
import Foundation

/// The full-filesystem backend's storage: the same `UserDefaults` keys and
/// representation the app has always written, so an upgrade keeps every
/// favourite, every recent and every folder's view.
///
/// `favorites`, `recents`, `recentFiles`, `lastDirectory`, `sortKey`,
/// `sortAscending`, `showsHidden`, `layout`, `folderLayouts`, `presetOrder`
/// and `hiddenPresets` keep their legacy shapes. Paths are stored absolute,
/// as before, and read back as paths relative to `/`. Visit times are the
/// one addition, under `recentVisits`, beside the path array rather than in
/// place of it: an older build reading these defaults still finds its list.
///
/// Only the full root uses this. The sandboxed backend is a different
/// namespace and stores its own record under its own key, so an old absolute
/// favourite is never reinterpreted as a container path.
///
/// A save writes only the keys whose value changed since the last load or
/// save: a key this build did not touch keeps whatever an older or newer
/// build put there, and recording a visit does not re-serialise every
/// folder's layout.
@MainActor
public final class LocalPreferencesDefaults: DefaultStorage {
    public typealias Value = LocalFilePreferences

    private let defaults: UserDefaults
    /// What the keys held when last read or written, per key group, so a
    /// save can leave untouched groups alone.
    private var known: LocalFilePreferences?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> LocalFilePreferences? {
        let value = read()
        known = value
        return value
    }

    private func read() -> LocalFilePreferences {
        var files = FileBackendPreferences()
        if let favorites = defaults.stringArray(forKey: "favorites") {
            files.favorites = favorites.compactMap(Self.path)
        }
        // The legacy filter: an older build recorded opened files too, under
        // a second key, and hid them from the directory list by subtraction.
        let filesOnly = Set(defaults.stringArray(forKey: "recentFiles") ?? [])
        let visits = defaults.dictionary(forKey: "recentVisits") as? [String: Double] ?? [:]
        files.recents = (defaults.stringArray(forKey: "recents") ?? [])
            .filter { !filesOnly.contains($0) }
            .compactMap { absolute in
                Self.path(absolute).map {
                    FileBackendPreferences.Visit(path: $0, visited: visits[absolute].map(Date.init(timeIntervalSince1970:)))
                }
            }
        files.lastDirectory = defaults.string(forKey: "lastDirectory").flatMap(Self.path)
        files.sortKey = defaults.string(forKey: "sortKey").flatMap(FileSortKey.init) ?? .name
        files.sortAscending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        files.showsHidden = defaults.object(forKey: "showsHidden") as? Bool ?? false
        files.layout = defaults.string(forKey: "layout").flatMap(BrowserLayout.init) ?? .list
        let layouts = defaults.dictionary(forKey: "folderLayouts") as? [String: String] ?? [:]
        files.folderLayouts = Dictionary(uniqueKeysWithValues: layouts.compactMap { absolute, raw in
            guard let path = Self.path(absolute), let layout = BrowserLayout(rawValue: raw) else { return nil }
            return (path, layout)
        })
        let order = (defaults.array(forKey: "presetOrder") as? [Int] ?? []).compactMap(LocalPreset.init(rawValue:))
        let hidden = Set((defaults.array(forKey: "hiddenPresets") as? [Int] ?? []).compactMap(LocalPreset.init(rawValue:)))
        return LocalFilePreferences(files: files, presetOrder: order, hiddenPresets: hidden)
    }

    public func save(_ value: LocalFilePreferences) throws {
        let files = value.files
        let was = known
        func changed<T: Equatable>(_ keyPath: KeyPath<LocalFilePreferences, T>) -> Bool {
            guard let was else { return true }
            return was[keyPath: keyPath] != value[keyPath: keyPath]
        }
        if changed(\.files.favorites) {
            if let favorites = files.favorites {
                defaults.set(favorites.map(Self.absolute), forKey: "favorites")
            } else {
                defaults.removeObject(forKey: "favorites")
            }
        }
        if changed(\.files.recents) {
            defaults.set(files.recents.map { Self.absolute($0.path) }, forKey: "recents")
            var visits: [String: Double] = [:]
            for visit in files.recents {
                if let date = visit.visited {
                    visits[Self.absolute(visit.path)] = date.timeIntervalSince1970
                }
            }
            defaults.set(visits, forKey: "recentVisits")
            defaults.removeObject(forKey: "recentFiles")
        }
        if changed(\.files.lastDirectory) {
            if let last = files.lastDirectory {
                defaults.set(Self.absolute(last), forKey: "lastDirectory")
            } else {
                defaults.removeObject(forKey: "lastDirectory")
            }
        }
        if changed(\.files.sortKey) { defaults.set(files.sortKey.rawValue, forKey: "sortKey") }
        if changed(\.files.sortAscending) { defaults.set(files.sortAscending, forKey: "sortAscending") }
        if changed(\.files.showsHidden) { defaults.set(files.showsHidden, forKey: "showsHidden") }
        if changed(\.files.layout) { defaults.set(files.layout.rawValue, forKey: "layout") }
        if changed(\.files.folderLayouts) {
            defaults.set(
                Dictionary(uniqueKeysWithValues: files.folderLayouts.map { (Self.absolute($0.key), $0.value.rawValue) }),
                forKey: "folderLayouts"
            )
        }
        if changed(\.presetOrder) { defaults.set(value.presetOrder.map(\.rawValue), forKey: "presetOrder") }
        if changed(\.hiddenPresets) { defaults.set(value.hiddenPresets.map(\.rawValue).sorted(), forKey: "hiddenPresets") }
        known = value
    }

    /// `/var/mobile` ↔ `var/mobile`; `/` ↔ the root. A stored string that is
    /// not a path — one with `..` in it, say — is dropped rather than
    /// guessed at.
    static func path(_ absolute: String) -> ServicePath? {
        try? ServicePath(absolute)
    }

    static func absolute(_ path: ServicePath) -> String {
        "/" + path.description
    }
}
