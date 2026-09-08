import Foundation

extension Notification.Name {
    /// A preference changed somewhere other than the screen that renders it —
    /// in practice, the settings screen. Browsers re-read their layout and
    /// re-apply their snapshot; a modal settings screen never triggers the
    /// presenting controller's appearance callbacks, so there is nothing else
    /// that would tell them.
    static let filaPreferencesChanged = Notification.Name("wiki.qaq.fila.preferences")
}

enum FileSortKey: String, CaseIterable {
    case name
    case date
    case size
    case kind
}

enum BrowserLayout: String, CaseIterable {
    case list
    case grid
}

/// Where the browser opens on launch. `AppPreferences.launchDirectory` resolves it
/// — the value is a choice, and only `AppPreferences` knows what was last visited.
enum LaunchLocation: String, CaseIterable {
    case root
    case home
    case lastVisited
}

/// Everything the app remembers between launches.
///
/// `UserDefaults` rather than a store of our own: it is a handful of switches
/// and a few strings, it has to survive a respring, and nothing here is worth a
/// file format. Lists are capped so a long session cannot grow the plist
/// without bound.
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    static let recentLimit = 40
    /// How many folders may remember their own view. See `layout(for:)`.
    static let folderLayoutLimit = 200

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Browsing

    var sortKey: FileSortKey {
        get { defaults.string(forKey: "sortKey").flatMap(FileSortKey.init) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "sortKey") }
    }

    /// The Applications page's own order and scope, separate from the file
    /// list's: an app list sorted by size or date has no meaning.
    var appSort: AppSort {
        get { defaults.string(forKey: "appSort").flatMap(AppSort.init) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "appSort") }
    }

    var appScope: AppScope {
        get { defaults.string(forKey: "appScope").flatMap(AppScope.init) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "appScope") }
    }

    var isAscending: Bool {
        get { defaults.object(forKey: "sortAscending") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sortAscending") }
    }

    /// The view a folder gets when it has no opinion of its own.
    var layout: BrowserLayout {
        get { defaults.string(forKey: "layout").flatMap(BrowserLayout.init) ?? .list }
        set { defaults.set(newValue.rawValue, forKey: "layout") }
    }

    var showsHidden: Bool {
        get { defaults.object(forKey: "showsHidden") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "showsHidden") }
    }

    var launchLocation: LaunchLocation {
        get { defaults.string(forKey: "launchLocation").flatMap(LaunchLocation.init) ?? .root }
        set { defaults.set(newValue.rawValue, forKey: "launchLocation") }
    }

    /// The last visited directory, including when recent history is disabled.
    var lastDirectory: String {
        get { defaults.string(forKey: "lastDirectory") ?? "/" }
        set { defaults.set(newValue, forKey: "lastDirectory") }
    }

    /// Where the browser opens.
    ///
    /// `/var/mobile` rather than `NSHomeDirectory()`: the app's own container
    /// is the one directory a root file manager's user is *not* looking for.
    /// Checked rather than assumed, because the Mac development loop has no
    /// such directory and launching into one the daemon cannot list would look
    /// like the daemon being broken.
    var launchDirectory: String {
        if case .local(.container) = FileSession.shared.hello?.backend {
            // A restored external path may have lost its temporary grant.
            // Start in the app container; explicit navigation can still ask
            // the backend for other paths and receive the real permission error.
            return NSHomeDirectory()
        }
        switch launchLocation {
        case .root: return "/"
        case .home: return FileManager.default.fileExists(atPath: "/var/mobile") ? "/var/mobile" : "/"
        case .lastVisited: return lastDirectory
        }
    }

    /// The view for one folder: its own if it has one, the last-used default
    /// otherwise.
    ///
    /// Always per-folder, with no switch. Whether to remember is not a question
    /// a person has an opinion about — remembering is what every file manager
    /// does and what the eye expects — and a preference for it was a setting
    /// about a setting, which is the shape that makes a settings screen long
    /// without making the app more capable.
    func layout(for path: String) -> BrowserLayout {
        folderLayouts[path].flatMap(BrowserLayout.init) ?? layout
    }

    func setLayout(_ value: BrowserLayout, for path: String) {
        // The global default follows the most recent choice, so a folder with
        // no opinion of its own looks like the last one that did.
        layout = value
        var map = folderLayouts
        // ponytail: the map is dropped wholesale when it overflows rather than
        // evicting least-recently-used, which would need a second structure to
        // hold the order. The cost of being wrong is that some folders forget
        // their view; make it an LRU the day anyone notices.
        if map.count >= Self.folderLayoutLimit {
            map = [:]
        }
        map[path] = value.rawValue
        defaults.set(map, forKey: "folderLayouts")
    }

    private var folderLayouts: [String: String] {
        defaults.dictionary(forKey: "folderLayouts") as? [String: String] ?? [:]
    }

    // MARK: - Sidebar presets

    var presetOrder: [SidebarLocation.Position] {
        get {
            let saved = (defaults.array(forKey: "presetOrder") as? [Int] ?? [])
                .compactMap(SidebarLocation.Position.init(rawValue:))
            var seen = Set<SidebarLocation.Position>()
            return (saved + SidebarLocation.Position.allCases).filter { seen.insert($0).inserted }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "presetOrder")
            NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
        }
    }

    func isPresetEnabled(_ preset: SidebarLocation.Position) -> Bool {
        !(defaults.array(forKey: "hiddenPresets") as? [Int] ?? []).contains(preset.rawValue)
    }

    func setPreset(_ preset: SidebarLocation.Position, enabled: Bool) {
        var hidden = Set(defaults.array(forKey: "hiddenPresets") as? [Int] ?? [])
        if enabled {
            hidden.remove(preset.rawValue)
        } else {
            hidden.insert(preset.rawValue)
        }
        defaults.set(hidden.sorted(), forKey: "hiddenPresets")
        NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
    }

    // MARK: - File operations

    /// The regular delete action follows this choice; items already in the trash
    /// are always deleted permanently.
    var usesTrash: Bool {
        get { defaults.object(forKey: "usesTrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "usesTrash") }
    }

    /// Text viewer: soft-wrap long lines. Off is what a log or a minified
    /// file wants; on is what everything else wants.
    var wrapsLines: Bool {
        get { defaults.object(forKey: "wrapsLines") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wrapsLines") }
    }

    /// Text viewer: colour by grammar. Off reads a file as plain text.
    var highlightsSyntax: Bool {
        get { defaults.object(forKey: "highlightsSyntax") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightsSyntax") }
    }

    /// Whether the app may *offer* to send `overrideGuard` on a destructive
    /// job. Off by default, and being on never overrides anything on its own:
    /// it adds a second, separately-confirmed action to the delete sheet. The
    /// daemon is still the only thing that decides, and it still refuses the
    /// volume root and the bootstrap root whatever this says.
    var allowsGuardOverride: Bool {
        get { defaults.object(forKey: "allowsGuardOverride") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "allowsGuardOverride") }
    }

    // MARK: - System features

    /// The user's half of `SystemCapabilities`: on by default, and turning one off
    /// is for a jailbreak whose system-protection bypass is partial or absent,
    /// where a private-framework call may hang or crash the app. Off means the
    /// feature is not offered at all — no LaunchServices query, no Run menu —
    /// not that it is offered and fails.
    var showsApplications: Bool {
        get { defaults.object(forKey: "showsApplications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showsApplications") }
    }

    var runsPrograms: Bool {
        get { defaults.object(forKey: "runsPrograms") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "runsPrograms") }
    }

    /// On by default, because a script written `#!/bin/sh` is every script and
    /// a rootless device has no `/bin/sh` — off, the kernel refuses it and the
    /// user sees a file that will not run. Off is for the case where honouring
    /// the line is wrong: a script that means the system's own interpreter,
    /// on a bootstrap that ships a different one under the same name.
    var redirectsScriptInterpreters: Bool {
        get { defaults.object(forKey: "redirectsScriptInterpreters") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "redirectsScriptInterpreters") }
    }

    // MARK: - WebDAV server

    /// 8080 rather than 80: a port under 1024 needs privilege the app does not
    /// have, and the app is `mobile` on purpose.
    var serverPort: UInt16 {
        get {
            let stored = defaults.integer(forKey: "serverPort")
            return (1024 ... 65535).contains(stored) ? UInt16(stored) : 8080
        }
        set { defaults.set(Int(newValue), forKey: "serverPort") }
    }

    var serverUsername: String {
        get {
            let stored = defaults.string(forKey: "serverUsername") ?? ""
            return stored.isEmpty ? "fila" : stored
        }
        set { defaults.set(newValue, forKey: "serverUsername") }
    }

    /// **Generated on first read, never empty.** There is no shipped default —
    /// a fixed password on a server that publishes `/` is a published
    /// credential — so each install draws its own, and the screen shows it in
    /// the clear because the user has to type it into another device.
    ///
    /// ponytail: `UserDefaults`, not the keychain. The app's container is
    /// readable by root, and root is the premise of this entire application —
    /// the keychain would raise the bar for a non-root attacker on the device
    /// and for nobody else. Move it if Fila ever runs somewhere that is not
    /// already rooted.
    var serverPassword: String {
        get {
            if let stored = defaults.string(forKey: "serverPassword"), !stored.isEmpty {
                return stored
            }
            // No 0/O/1/l/I: it is read off one screen and typed into another.
            let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let generated = String((0 ..< 10).map { _ in alphabet.randomElement()! })
            defaults.set(generated, forKey: "serverPassword")
            return generated
        }
        set { defaults.set(newValue, forKey: "serverPassword") }
    }

    /// The folder the server publishes. Fila's own Documents by default: a
    /// jailbroken device is one the user chose to open, but a network share
    /// that starts at `/` is one they did not. Anything else is their choice.
    /// Stored as typed; `FileSharingServer` canonicalises it through the
    /// daemon at start, because the server compares canonical paths.
    var serverRoot: String {
        get {
            let stored = defaults.string(forKey: "serverRoot") ?? ""
            return stored.isEmpty ? Self.defaultServerRoot : stored
        }
        set { defaults.set(newValue, forKey: "serverRoot") }
    }

    static var defaultServerRoot: String {
        (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).path)
            ?? NSHomeDirectory() + "/Documents"
    }

    /// Whether the server is left up when the app leaves the screen. Off by
    /// default, and even on it only buys the background grace period — see
    /// `FileSharingServer.applicationWillResign`.
    var keepsServerRunningInBackground: Bool {
        get { defaults.object(forKey: "serverBackground") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "serverBackground") }
    }

    // MARK: - Lists

    var favorites: [String] {
        get { defaults.stringArray(forKey: "favorites") ?? Self.defaultFavorites }
        set { store(newValue, forKey: "favorites") }
    }

    var recents: [String] {
        get {
            let files = Set(defaults.stringArray(forKey: "recentFiles") ?? [])
            return (defaults.stringArray(forKey: "recents") ?? []).filter { !files.contains($0) }
        }
        set {
            defaults.removeObject(forKey: "recentFiles")
            store(newValue, forKey: "recents")
        }
    }

    // Tabs were a `[String]` of paths here. They are `BrowserTabStore` now: a tab has
    // a history, a scroll position and a selection, none of which fit in a path.

    func toggleFavorite(_ path: String) {
        var list = favorites
        if let index = list.firstIndex(of: path) {
            list.remove(at: index)
        } else {
            list.append(path)
        }
        favorites = list
    }

    func isFavorite(_ path: String) -> Bool {
        favorites.contains(path)
    }

    /// Whether visits are recorded at all. On by default — the list is the
    /// point of having one — but this is a root file manager, so the trail it
    /// leaves is a list of every sensitive directory its user opened, sitting
    /// in a plist any other root process can read. That is a reason to be able
    /// to say no.
    var recordsRecents: Bool {
        get { defaults.object(forKey: "recordsRecents") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "recordsRecents")
            // Turning it off clears what is already there. A switch that stops
            // adding but leaves the history behind has not done what its label
            // says, and here the history is the thing being objected to.
            if !newValue {
                recents = []
            }
        }
    }

    /// A recent that is gone from disk is dropped, not left to fail again.
    func forgetRecent(_ path: String) {
        recents.removeAll { $0 == path }
    }

    func noteVisit(_ path: String, isDirectory: Bool) {
        guard recordsRecents, isDirectory else { return }
        var list = recents
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recents = Array(list.prefix(Self.recentLimit))
    }

    private func store(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .filaSidebarChanged, object: nil)
    }

    private static let defaultFavorites = [
        "/var/mobile/Documents",
        "/var/mobile/Library/Preferences",
        "/etc",
    ]
}
