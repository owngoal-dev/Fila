import Foundation

extension Notification.Name {
    /// A tab was opened, closed, reordered, or switched to. The switcher
    /// redraws; nothing else listens, because the shell is the only other
    /// thing that touches tabs and it is what posted this.
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
    /// about which way is out. See `BrowserViewController.open(directory:)` for
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
        // Inside a sandbox, Home is the first useful ancestor; avoid adding
        // Back destinations that iOS will not let this process list.
        if case .local(.container) = FileSession.shared.hello?.backend {
            let homePaths = [NSHomeDirectory(), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path]
            if let home = chain.firstIndex(where: homePaths.contains) {
                return Array(chain[home...])
            }
        }
        return chain
    }
}

/// Every open tab, and which one is in front.
///
/// `UserDefaults` for the same reason everything else in `AppPreferences` is: it
/// is a small amount of text that has to survive a respring. Both dimensions
/// are capped — the number of tabs and the depth each one remembers — because a
/// long session must not grow the plist without bound, and because the tab list
/// sits behind `fila://`, which is an unauthenticated entry point.
@MainActor
final class BrowserTabStore {
    static let shared = BrowserTabStore()

    /// How many tabs may exist at once. Roughly what a switcher grid shows
    /// without becoming a scrolling archive of everywhere you have ever been.
    static let limit = 16

    /// How deep one tab's remembered history goes. Beyond this the oldest
    /// ancestors are dropped: the way *out* of a folder is the breadcrumb, not
    /// thirty Back taps, so the far end of a long walk is worth nothing.
    static let depthLimit = 32

    private let defaults: UserDefaults

    private(set) var tabs: [BrowserTab]
    private(set) var currentID: UUID

    private init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        var stored = Self.load(from: defaults)
        if case .local(.container) = FileSession.shared.hello?.backend {
            for index in stored.indices {
                if ["/", "/var/mobile"].contains(stored[index].path) {
                    stored[index].stack = BrowserTab.chain(to: NSHomeDirectory())
                    stored[index].offsets = [:]
                    stored[index].selection = nil
                } else {
                    stored[index].stack = BrowserTab.chain(to: stored[index].path)
                }
            }
        }
        tabs = stored.isEmpty ? [BrowserTab(path: AppPreferences.shared.launchDirectory)] : stored
        // The remembered tab, if it is still one of them — a plist that was
        // edited, truncated or written by an older build is not a reason to
        // start with no tab at all.
        let remembered = defaults.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        currentID = tabs.first { $0.id == remembered }?.id ?? tabs[0].id
    }

    // MARK: - Reading

    var current: BrowserTab {
        // `currentID` is only ever set to a tab that exists, and `tabs` is
        // never empty — but the fallback is the first tab rather than a crash,
        // because a corrupt plist is not worth taking the app down for.
        tabs.first { $0.id == currentID } ?? tabs[0]
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
        tabs.append(tab)
        currentID = tab.id
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
        currentID = id
        save()
    }

    /// Closes one tab. Closing the last one leaves a fresh tab at the launch
    /// directory rather than an empty shell — there is always somewhere to be.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            tabs = [BrowserTab(path: AppPreferences.shared.launchDirectory)]
        }
        // Closing the tab you are on lands on the one that took its place, or
        // on the new last one — the same thing every tabbed app does.
        if currentID == id {
            currentID = tabs[min(index, tabs.count - 1)].id
        }
        save()
    }

    func closeAll() {
        tabs = [BrowserTab(path: AppPreferences.shared.launchDirectory)]
        currentID = tabs[0].id
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
        tabs = order.compactMap { id in tabs.first { $0.id == id } }
        save()
    }

    /// Writes down where the current tab is. Called by the shell whenever the
    /// live stack could have changed — a push, a pop, a tab switch, the app
    /// going to the background — because the shell is the only thing that knows
    /// what is actually on screen.
    func record(stack: [String], offsets: [String: Double], selection: String?) {
        guard let top = stack.last, let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
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
        tabs[index].stack = trimmed
        // Offsets for directories that are no longer in the stack are dropped
        // with them, which is what keeps this dictionary from being a log.
        tabs[index].offsets = offsets.filter { trimmed.contains($0.key) }
        tabs[index].selection = selection
        save(notify: false)
    }

    // MARK: - Storage

    private static let tabsKey = "tabState"
    private static let currentKey = "currentTab"
    /// The `[String]` list this replaced. Read once, to carry a person's open
    /// tabs across the upgrade, then never again.
    private static let legacyKey = "tabs"

    private static func load(from defaults: UserDefaults) -> [BrowserTab] {
        if let data = defaults.data(forKey: tabsKey),
           let decoded = try? JSONDecoder().decode([BrowserTab].self, from: data)
        {
            return decoded.filter { !$0.stack.isEmpty }
        }
        return (defaults.stringArray(forKey: legacyKey) ?? []).map { BrowserTab(path: $0) }
    }

    /// `notify: false` for the one caller that is recording what is already on
    /// screen: telling the switcher to redraw for a scroll position it cannot
    /// see would be a notification per scroll.
    private func save(notify: Bool = true) {
        defaults.set(try? JSONEncoder().encode(tabs), forKey: Self.tabsKey)
        defaults.set(currentID.uuidString, forKey: Self.currentKey)
        defaults.removeObject(forKey: Self.legacyKey)
        if notify {
            NotificationCenter.default.post(name: .filaTabsChanged, object: nil)
        }
    }
}
