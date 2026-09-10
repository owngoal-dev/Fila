import Foundation
import UIKit

extension Notification.Name {
    /// A tab was opened, closed, reordered, or switched to. Posted with the
    /// store that changed as the object: the switcher and the container of
    /// that window redraw, and another window's — with a store of its own —
    /// hears nothing, because nothing of its changed.
    static let filaTabsChanged = Notification.Name("wiki.qaq.fila.tabs")
}

/// One tab: a directory stack, and where the user was in it.
///
/// Deliberately *not* a live view controller. A tab has to survive a respring
/// and a `UINavigationController` does not, so a tab is written down as strings
/// and rebuilt after launch. During the process lifetime, TabContainer keeps
/// each tab's navigation alive so switching preserves the page on top.
///
/// Anything a tab shows that is not a directory — a viewer, an editor, a
/// terminal — is pushed on top of this at runtime and is deliberately absent
/// here: none of them can be rebuilt from a path, and a tab that reopened a
/// half-finished edit as if nothing had happened would be lying.
struct BrowserTab: Codable {
    /// Stable across reorders and closes. The switcher diffs on it, and the
    /// current tab is remembered by it — an index would follow the wrong tab
    /// the moment one before it is closed.
    var id = UUID()

    /// Directories, outermost first. `last` is the one on screen. Never empty:
    /// a tab with nowhere to be is not a tab, and `BrowserTabStore` maintains that.
    var stack: [String]

    /// Where each directory in `stack` was left, vertically. Keyed by path
    /// rather than by depth so a tab that walks back up and down again lands
    /// where it was both times.
    var offsets: [String: Double] = [:]

    /// The row highlighted in the top directory, by name. A name and not an
    /// index for the same reason `fila://reveal` uses one: the listing streams,
    /// so the row does not exist when the tab is rebuilt.
    var selection: String?

    /// The directory on screen.
    var path: String {
        stack.last ?? "/"
    }

    /// What the switcher calls this tab.
    var title: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

extension BrowserTab {
    /// A tab that starts at one directory, with the way out of it already in
    /// the stack.
    ///
    /// **The stack is the path.** A tab opened at `/var/mobile/Documents` holds
    /// `/`, `/var`, `/var/mobile`, `/var/mobile/Documents` — so Back is always
    /// one component shallower and the breadcrumb and Back can never disagree
    /// about which way is out. See `FileBrowserViewController.open(directory:)` for
    /// the rule in full and for the bug that came of not having one.
    @MainActor init(path: String) {
        self.init(stack: Self.chain(to: path))
    }

    /// `/usr/local/bin` → `["/", "/usr", "/usr/local", "/usr/local/bin"]`.
    ///
    /// Purely a string split: these are the directories a person walked through
    /// to be here, not directories anything has checked exist. A component that
    /// turns out not to be there lists as empty, which is the honest answer and
    /// the same one typing the path into *Go to Path* gives.
    @MainActor static func chain(to path: String) -> [String] {
        var chain = ["/"]
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            chain.append(prefix)
        }
        // This is navigation history, not a filesystem permission boundary.
        // Inside a sandbox the backend's root — Documents — is where the
        // walk starts: nothing above it is offered, so neither Back nor the
        // breadcrumb leads there.
        if case .local(.container) = FileSession.shared.hello?.backend {
            let root = FileSession.shared.local.rootPath
            let roots = [root, URL(fileURLWithPath: root).resolvingSymlinksInPath().path]
            if let start = chain.firstIndex(where: roots.contains) {
                return Array(chain[start...])
            }
        }
        return chain
    }
}

/// One window's open tabs, and which one is in front.
///
/// One per window scene, not one for the app: with two Fila windows on an
/// iPad, a tab closed in one must not vanish from the other, and Close All
/// in one is not Close All in both. The list is keyed by the scene session's
/// `persistentIdentifier`, which is what iOS itself keys the window's
/// restoration by, so a window that comes back after a relaunch finds its
/// own tabs — and a window iOS has discarded takes its keys with it (see
/// `forget`).
///
/// `UserDefaults` for the same reason everything else in `AppPreferences` is: it
/// is a small amount of text that has to survive a respring. Both dimensions
/// are capped — the number of tabs and the depth each one remembers — because a
/// long session must not grow the plist without bound, and because the tab list
/// sits behind `fila://`, which is an unauthenticated entry point.
@MainActor
final class BrowserTabStore {
    /// How many tabs may exist at once. Roughly what a switcher grid shows
    /// without becoming a scrolling archive of everywhere you have ever been.
    private static let limit = 16

    /// How deep one tab's remembered history goes. Beyond this the oldest
    /// ancestors are dropped: the way *out* of a folder is the breadcrumb, not
    /// thirty Back taps, so the far end of a long walk is worth nothing.
    private static let depthLimit = 32

    /// How many windows' lists are kept for windows that are not open. A
    /// window closed on an iPad is discarded by iOS and its list goes then;
    /// this is the bound on what an installer's `uicache` — which drops every
    /// session without telling the app — can leave behind.
    private static let orphanLimit = 8

    private let defaults: UserDefaults

    /// The window this list belongs to: its scene session's persistent identifier.
    let sessionIdentifier: String

    /// The stores alive right now, by session. What a session connecting
    /// with no list of its own may adopt is a list whose window is *not*
    /// among these (nor among the sessions iOS still holds open).
    private static var live: Set<String> = []

    /// Whether a window with no list has already looked for one to adopt
    /// this launch. The first such window is the one an install's `uicache`
    /// or an upgrade left listless, and it takes the dropped list; a window
    /// the person opens later is a new window, and starts with one tab.
    private static var adoptionTried = false

    private struct State {
        var tabs: [BrowserTab]
        var currentID: UUID
    }

    /// Read on first use, not at construction: the scene connects — and this
    /// object is made — before the handshake has landed, and what a tab's
    /// chain looks like depends on which backend answered. Every reader
    /// waits for `FileSession.shared.hello` first (the container's
    /// `showCurrentTab`, a link's `ready()`), so by the first read the answer
    /// is known.
    private var state: State?

    init(sessionIdentifier: String, defaults: UserDefaults = .standard) {
        self.sessionIdentifier = sessionIdentifier
        self.defaults = defaults
        Self.live.insert(sessionIdentifier)
    }

    deinit {
        // Isolated state, touched from a nonisolated deinit. The shell makes
        // and releases the store on the main thread; the other arm is for a
        // last reference dropped by an autorelease pool elsewhere, which
        // must not trap on the executor check.
        let session = sessionIdentifier
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = Self.live.remove(session) }
        } else {
            Task { @MainActor in _ = Self.live.remove(session) }
        }
    }

    private var loaded: State {
        get {
            if let state { return state }
            let state = load()
            self.state = state
            return state
        }
        set { state = newValue }
    }

    // MARK: - Reading

    var tabs: [BrowserTab] { loaded.tabs }

    /// The tab in front of this window. Persisted so a relaunch lands where
    /// the person was.
    var currentID: UUID { loaded.currentID }

    var current: BrowserTab {
        // `currentID` is only ever set to a tab that exists, and `tabs` is
        // never empty — but the fallback is the first tab rather than a crash,
        // because a corrupt plist is not worth taking the app down for.
        let state = loaded
        return state.tabs.first { $0.id == state.currentID } ?? state.tabs[0]
    }

    var isFull: Bool {
        tabs.count >= Self.limit
    }

    // MARK: - Writing

    /// Opens `path` in a new tab and makes it current, or answers `nil` at the
    /// cap. The caller decides what to do instead — nothing here silently
    /// re-roots a tab a person is using.
    @discardableResult
    func open(_ path: String) -> BrowserTab? {
        guard !isFull else { return nil }
        let tab = BrowserTab(path: path)
        loaded.tabs.append(tab)
        loaded.currentID = tab.id
        save()
        return tab
    }

    /// The `fila://open?path=…&tab=new` path.
    ///
    /// Capped, and the cap drops the *new* tab rather than an old one: the list
    /// is on the other side of an unauthenticated entry point, so a page that
    /// keeps sending links must not be able to grow a preference without bound
    /// — nor to push a person's own tabs out of the switcher. A path already
    /// open is switched to rather than opened twice, so a page that sends the
    /// same link repeatedly costs nothing. Opening still happens either way,
    /// because the caller navigates regardless of what this answers.
    func openFromLink(_ path: String) {
        if let existing = tabs.first(where: { $0.path == path }) {
            select(existing.id)
            return
        }
        open(path)
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        loaded.currentID = id
        save()
    }

    /// Closes one tab. Closing the last one leaves a fresh tab at the launch
    /// directory rather than an empty shell — there is always somewhere to be.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        loaded.tabs.remove(at: index)
        if loaded.tabs.isEmpty {
            loaded.tabs = [BrowserTab(path: AppPreferences.shared.launchDirectory)]
        }
        // Closing the tab you are on lands on the one that took its place, or
        // on the new last one — the same thing every tabbed app does.
        if loaded.currentID == id {
            loaded.currentID = loaded.tabs[min(index, loaded.tabs.count - 1)].id
        }
        save()
    }

    func closeAll() {
        loaded.tabs = [BrowserTab(path: AppPreferences.shared.launchDirectory)]
        loaded.currentID = loaded.tabs[0].id
        save()
    }

    /// Puts the tabs in the order the switcher's snapshot ended up in.
    ///
    /// Taken as identifiers rather than as a from/to index pair because that is
    /// what a diffable data source's reordering transaction hands back — and
    /// because the snapshot is the thing the user actually rearranged. Ignored
    /// unless it is the same set: a reorder that has gained or lost a tab is a
    /// reorder racing a close, and the close wins.
    func reorder(to order: [UUID]) {
        guard Set(order) == Set(tabs.map(\.id)) else { return }
        let tabs = tabs
        loaded.tabs = order.compactMap { id in tabs.first { $0.id == id } }
        save()
    }

    /// Writes down where tab `id` is. Called by the shell whenever the live
    /// stack could have changed — a push, a pop, a tab switch, the app going
    /// to the background — because the shell is the only thing that knows
    /// what is actually on screen. The tab is named rather than taken to be
    /// the current one: a tab opened from a menu is current before its page
    /// is on screen, while the page being written down is still the old one.
    func record(_ id: UUID, stack: [String], offsets: [String: Double], selection: String?) {
        guard let top = stack.last, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // A stack is a path: each directory the parent of the next. The live
        // stack can hold a browser pushed over screens that are not
        // directories — the Applications list and an app's detail, a search's
        // hits — and those are not rebuilt (see `BrowserTab`), so a stack
        // written down as-is would put Back, after relaunch, somewhere the
        // person never was. Such a stack is written down as the top directory's
        // own chain instead: the same thing Back climbs after any jump.
        let isChain = zip(stack, stack.dropFirst()).allSatisfy { ($1 as NSString).deletingLastPathComponent == $0 }
        let stack = isChain ? stack : BrowserTab.chain(to: top)
        // The *outermost* directories are dropped when a walk runs long: the
        // folder you are in and the ones just above it are the ones Back is for.
        let trimmed = Array(stack.suffix(Self.depthLimit))
        loaded.tabs[index].stack = trimmed
        // Offsets for directories that are no longer in the stack are dropped
        // with them, which is what keeps this dictionary from being a log.
        loaded.tabs[index].offsets = offsets.filter { trimmed.contains($0.key) }
        loaded.tabs[index].selection = selection
        save(notify: false)
    }

    // MARK: - Storage

    /// Three keys per window, each suffixed `.<session identifier>`: the
    /// tabs, the current one, and when they were last written — the last so
    /// that a window with no list of its own adopts the *most recent* one
    /// left behind. The unsuffixed `tabState`/`currentTab` are the one list
    /// every window shared before this; they are read as the oldest orphan
    /// and never written again. `tabs`, the `[String]` before that, likewise.
    private enum Key {
        static let tabs = "tabState"
        static let current = "currentTab"
        static let written = "tabsWritten"
        static let legacyList = "tabs"

        /// One of the three, for one window.
        static func of(_ base: String, _ session: String) -> String { "\(base).\(session)" }
    }

    private func load() -> State {
        var stored = Self.read(
            Key.of(Key.tabs, sessionIdentifier), current: Key.of(Key.current, sessionIdentifier), from: defaults
        )
        var adoption: Adoption?
        if stored == nil, !Self.adoptionTried {
            Self.adoptionTried = true
            adoption = adoptOrphan()
            stored = adoption.map { ($0.tabs, $0.current) }
        }
        var tabs = stored?.tabs ?? []
        if case .local(.container) = FileSession.shared.hello?.backend {
            // A remembered directory this container does not hold — the
            // full root's launch directory from a build that had it, the
            // container root from a build that started at Home, or a path
            // under the container a sideloading tool's reinstall retired —
            // reopens at the root that exists. Anything inside keeps its
            // place and gets the chain that starts there.
            let root = FileSession.shared.local.rootPath
            let roots = [root, URL(fileURLWithPath: root).resolvingSymlinksInPath().path]
            for index in tabs.indices {
                let path = tabs[index].path
                if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    tabs[index].stack = BrowserTab.chain(to: path)
                } else {
                    tabs[index].stack = BrowserTab.chain(to: root)
                    tabs[index].offsets = [:]
                    tabs[index].selection = nil
                }
            }
        }
        if tabs.isEmpty {
            tabs = [BrowserTab(path: AppPreferences.shared.launchDirectory)]
        }
        // The remembered tab, if it is still one of them — a plist that was
        // edited, truncated or written by an older build is not a reason to
        // start with no tab at all.
        let current = tabs.first { $0.id == stored?.current }?.id ?? tabs[0].id
        let state = State(tabs: tabs, currentID: current)
        if let adoption {
            // Written under this session *before* the orphan's keys go: a
            // kill between the two — the app swiped away before the first
            // push records anything — must not lose the list to the code
            // that exists to keep it.
            self.state = state
            save(notify: false)
            Self.remove(adoption.session, from: defaults)
        }
        return state
    }

    /// A window's list as written, or nil when this window has none. An
    /// empty list is not nil: it is a list, and reads as one fresh tab.
    private static func read(_ tabsKey: String, current currentKey: String, from defaults: UserDefaults) -> (tabs: [BrowserTab], current: UUID?)? {
        guard let data = defaults.data(forKey: tabsKey),
              let decoded = try? JSONDecoder().decode([BrowserTab].self, from: data) else { return nil }
        return (decoded.filter { !$0.stack.isEmpty }, defaults.string(forKey: currentKey).flatMap(UUID.init(uuidString:)))
    }

    /// A window connecting with no list takes over the most recently written
    /// list whose window is gone — the one an install's `uicache` dropped
    /// along with every other session, so a person's tabs come back after an
    /// update; on an upgrade from the shared list, that list. The keys move
    /// to this session so no second window adopts the same tabs. Nothing to
    /// adopt means a fresh tab at the launch directory.
    ///
    /// A list is orphaned when its session is neither live in this process
    /// nor one iOS still holds open: a window in the switcher, disconnected
    /// but not discarded, keeps its list for its own return.
    private func adoptOrphan() -> Adoption? {
        let orphans = Self.orphans(in: defaults)
        // Keep the recent few, so a stack of dropped sessions cannot grow the
        // plist forever: the rest are the lists no window will come back for.
        for orphan in orphans.dropFirst(Self.orphanLimit) {
            Self.remove(orphan, from: defaults)
        }
        for session in orphans.prefix(Self.orphanLimit) {
            if let list = Self.readOrphan(session, from: defaults) {
                // The keys stay until `load` has written the list under this
                // session; see there.
                return Adoption(session: session, tabs: list.tabs, current: list.current)
            }
            // A list this build cannot decode — written in an older shape,
            // or cut short — is not one the next window will read either.
            // The ones behind it are still tried.
            Self.remove(session, from: defaults)
        }
        return nil
    }

    /// A list taken over from a window that is gone, and whose keys it came from.
    private struct Adoption {
        var session: String?
        var tabs: [BrowserTab]
        var current: UUID?
    }

    /// One orphan's list: a session's, or for `nil` the shared list every
    /// window once read, then the list of paths before that.
    private static func readOrphan(_ session: String?, from defaults: UserDefaults) -> (tabs: [BrowserTab], current: UUID?)? {
        if let session {
            return read(Key.of(Key.tabs, session), current: Key.of(Key.current, session), from: defaults)
        }
        if let shared = read(Key.tabs, current: Key.current, from: defaults) {
            return shared
        }
        let paths = defaults.stringArray(forKey: Key.legacyList) ?? []
        return paths.isEmpty ? nil : (paths.map { BrowserTab(path: $0) }, nil)
    }

    /// Sessions whose lists no window will read again, most recently written
    /// first. `nil` stands for the unsuffixed keys, and sorts last — they
    /// predate the timestamp.
    private static func orphans(in defaults: UserDefaults) -> [String?] {
        let held = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)).union(live)
        let prefix = Key.tabs + "."
        var found: [(session: String?, written: Double)] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let session = String(key.dropFirst(prefix.count))
            guard !session.isEmpty, !held.contains(session) else { continue }
            found.append((session, defaults.double(forKey: Key.of(Key.written, session))))
        }
        if defaults.object(forKey: Key.tabs) != nil || defaults.object(forKey: Key.legacyList) != nil {
            found.append((nil, -.infinity))
        }
        return found.sorted { $0.written > $1.written }.map(\.session)
    }

    private static func remove(_ session: String?, from defaults: UserDefaults) {
        if let session {
            for base in [Key.tabs, Key.current, Key.written] {
                defaults.removeObject(forKey: Key.of(base, session))
            }
        } else {
            defaults.removeObject(forKey: Key.tabs)
            defaults.removeObject(forKey: Key.current)
            defaults.removeObject(forKey: Key.legacyList)
        }
    }

    /// Drops the lists of windows iOS has discarded — closed in the app
    /// switcher, or expired. The one place a window's keys are removed on
    /// purpose: a session that is merely disconnected is one iOS means to
    /// bring back.
    static func forget(_ sessions: some Sequence<String>, defaults: UserDefaults = .standard) {
        for session in sessions {
            remove(session, from: defaults)
            live.remove(session)
        }
    }

    /// `notify: false` for the one caller that is recording what is already on
    /// screen: telling the switcher to redraw for a scroll position it cannot
    /// see would be a notification per scroll.
    private func save(notify: Bool = true) {
        let state = loaded
        defaults.set(try? JSONEncoder().encode(state.tabs), forKey: Key.of(Key.tabs, sessionIdentifier))
        defaults.set(state.currentID.uuidString, forKey: Key.of(Key.current, sessionIdentifier))
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: Key.of(Key.written, sessionIdentifier))
        if notify {
            NotificationCenter.default.post(name: .filaTabsChanged, object: self)
        }
    }
}
