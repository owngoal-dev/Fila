import Foundation

/// A `fila://` link, resolved into the one destination it means.
///
/// # Read-only by construction
///
/// **Every case below navigates, reveals or inspects. None of them changes the
/// filesystem, and none of them ever will.**
///
/// A URL scheme is an unauthenticated entry point. Any app on the device, and
/// any web page the user taps a link in, can open `fila://…`: there is no audit
/// token, no entitlement and no caller identity behind it, unlike every request
/// that reaches `filad`. The app is simply told to do something by a stranger —
/// and this app drives a root daemon.
///
/// So `fila://delete?path=/System` arriving from a web page has to be
/// impossible, and the way it is made impossible is *not* a confirmation
/// dialog: it is that there is no `delete` case here for the parser to produce.
/// A reviewer checks that boundary by reading this one enum. Write verbs would
/// need a design where the app shows exactly what is about to happen and the
/// user confirms it against the real path — a different piece of work, not an
/// extension of this one.
///
/// Read-only is not a reason to trust the bytes. Every path is bounded and
/// canonicalised by `canonical(_:)` before it leaves this file, and `filad`
/// calls `realpath(3)` and runs `FilaGuard` again on whatever finally reaches
/// it. That is defence in depth, not an excuse for the first layer.
enum FilaLink: Equatable {
    /// `fila:///var/mobile/Documents` — and `fila://open?path=…`.
    case directory(String)
    /// `fila://open?path=…&tab=new`.
    case newTab(String)
    /// `fila://reveal?path=…` — the parent directory of the item.
    case reveal(String)
    /// `fila://view?path=…`.
    case view(String)
    /// `fila://info?path=…`.
    case info(String)
    /// `fila://search?query=…[&path=/where]`.
    case search(query: String, root: String)
    /// `fila://app?bundle=com.example.thing[&container=bundle|data]`.
    case app(bundle: String, container: AppContainer)
    /// `fila://apps`.
    case installedApps
    /// `fila://settings`.
    case settings

    enum AppContainer: String {
        case bundle
        case data
    }
}

extension FilaLink {
    static let scheme = "fila"

    /// `PATH_MAX`. A longer string cannot name a file, so it is not a path — it
    /// is somebody finding out how much the parser will swallow.
    static let pathByteLimit = 1_024
    /// A search needle is typed by a person; anything longer is not one.
    static let queryByteLimit = 256
    /// Longer than any reverse-DNS identifier the system will install.
    static let bundleByteLimit = 256

    /// The single place that decides what a `fila://` URL means. Everything it
    /// does not recognise returns nil, and the caller says so out loud.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // First value wins. A duplicated key is either a mistake or an attempt
        // to make the link read one way and act another; either way, the
        // leftmost spelling is the one a person reading the URL sees.
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            let name = item.name.lowercased()
            if values[name] == nil { values[name] = value }
        }
        let wantsNewTab = values["tab"]?.lowercased() == "new"

        // No host means the path is the destination: `fila:///var/mobile` is
        // the natural spelling and the one people guess. `fila://var/mobile`
        // is not it — that names the verb "var" — and failing visibly there
        // teaches the third slash.
        let verb = components.host?.lowercased() ?? ""
        guard !verb.isEmpty else {
            guard let path = Self.canonical(url.path) else { return nil }
            self = wantsNewTab ? .newTab(path) : .directory(path)
            return
        }

        switch verb {
        case "open":
            guard let path = Self.path(values) else { return nil }
            self = wantsNewTab ? .newTab(path) : .directory(path)
        case "reveal":
            guard let path = Self.path(values) else { return nil }
            self = .reveal(path)
        case "view":
            guard let path = Self.path(values) else { return nil }
            self = .view(path)
        case "info":
            guard let path = Self.path(values) else { return nil }
            self = .info(path)
        case "search":
            guard let query = values["query"], Self.isPlausibleQuery(query) else { return nil }
            // Searching from `/` is the useful default: a link that names a
            // needle and no root wants the whole device.
            self = .search(query: query, root: Self.path(values) ?? "/")
        case "app":
            guard let bundle = values["bundle"], Self.isBundleIdentifier(bundle) else { return nil }
            let container = values["container"]?.lowercased()
            self = .app(bundle: bundle, container: container.flatMap(AppContainer.init(rawValue:)) ?? .bundle)
        case "apps":
            self = .installedApps
        case "settings":
            self = .settings
        default:
            return nil
        }
    }

    private static func path(_ values: [String: String]) -> String? {
        values["path"].flatMap(canonical)
    }

    /// Bounds and canonicalises a path handed over by a stranger.
    ///
    /// Absolute, no NUL, no longer than a path can be, empty and repeated
    /// separators dropped, and `.` / `..` collapsed so a link cannot spell one
    /// place and mean another.
    ///
    /// The collapse is lexical, so `a/b/..` resolves differently here than on
    /// disk when `b` is a symlink. That costs nothing: every verb in this file
    /// is read-only, and the daemon canonicalises with `realpath(3)` and runs
    /// `FilaGuard` on whatever it is finally asked for.
    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= pathByteLimit, !path.contains("\0") else { return nil }
        var stack: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(component)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    static func isPlausibleQuery(_ query: String) -> Bool {
        !query.isEmpty && query.utf8.count <= queryByteLimit && !query.contains("\0")
    }

    /// Reverse-DNS, near enough. The point is not to validate an identifier the
    /// installation database will validate anyway — it is that this string gets
    /// compared against every installed app's identifier, so it must be a short
    /// run of the characters an identifier can contain and nothing else. ASCII
    /// only: a Cyrillic `а` that looks like an `a` has no business matching one.
    static func isBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= bundleByteLimit else { return false }
        return identifier.unicodeScalars.allSatisfy {
            ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9").contains($0)
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

#if DEBUG
    extension FilaLink {
        /// The parser's check, run once at launch in Debug builds.
        ///
        /// It lives here rather than in `Packages/FilaKit/Tests` because this
        /// type is app code and the app target has no test target: a package
        /// test cannot see it. Moving `FilaLink.swift` into a `FilaLinks`
        /// product under `Packages/FilaKit` — it imports nothing but Foundation
        /// — is the change that would make it a real `swift test` suite, and is
        /// the only reason to make one.
        static func runSelfCheck() {
            func parse(_ string: String) -> FilaLink? {
                URL(string: string).flatMap(FilaLink.init)
            }

            // The spelling a person types.
            assert(parse("fila:///var/mobile/Documents") == .directory("/var/mobile/Documents"))
            assert(parse("fila:///") == .directory("/"))
            assert(parse("FILA:///etc") == .directory("/etc"))
            assert(parse("fila://open?path=/var/mobile") == .directory("/var/mobile"))

            // Percent-encoding, decoded in both spellings.
            assert(parse("fila:///var/mobile/My%20Docs") == .directory("/var/mobile/My Docs"))
            assert(parse("fila://open?path=%2Fvar%2Fmobile%2FMy%20Docs") == .directory("/var/mobile/My Docs"))

            // Traversal, collapsed rather than passed through.
            assert(parse("fila:///var/mobile/../../etc") == .directory("/etc"))
            assert(parse("fila://open?path=/../../..") == .directory("/"))
            assert(parse("fila:///var//./mobile/") == .directory("/var/mobile"))

            // Refusals: unknown verb, missing path, relative path, a path that
            // is not a path.
            assert(parse("fila://delete?path=/System") == nil)
            assert(parse("fila://open") == nil)
            assert(parse("fila://open?path=") == nil)
            assert(parse("fila://open?path=var/mobile") == nil)
            assert(parse("fila://var/mobile") == nil)
            assert(parse("fila://") == nil)
            assert(parse("https://example.com/") == nil)
            assert(parse("fila://open?path=/" + String(repeating: "a", count: pathByteLimit)) == nil)

            // Asserted against `canonical` rather than through a URL: how
            // `URL(string:)` treats an embedded `%00` has changed between
            // Foundation versions, and the bound that matters is this one.
            assert(canonical("/var/mobile/a\0b") == nil)
            assert(canonical("/" + String(repeating: "a", count: pathByteLimit)) == nil)
            assert(canonical("var/mobile") == nil)
            assert(canonical("") == nil)

            // The rest of the vocabulary.
            assert(parse("fila://open?path=/etc&tab=new") == .newTab("/etc"))
            assert(parse("fila:///etc?tab=new") == .newTab("/etc"))
            assert(parse("fila://reveal?path=/etc/hosts") == .reveal("/etc/hosts"))
            assert(parse("fila://view?path=/etc/hosts") == .view("/etc/hosts"))
            assert(parse("fila://info?path=/etc/hosts") == .info("/etc/hosts"))
            assert(parse("fila://search?query=hosts") == .search(query: "hosts", root: "/"))
            assert(parse("fila://search?query=hosts&path=/etc") == .search(query: "hosts", root: "/etc"))
            assert(parse("fila://search") == nil)
            assert(parse("fila://app?bundle=com.example.thing") == .app(bundle: "com.example.thing", container: .bundle))
            assert(parse("fila://app?bundle=com.example.thing&container=data")
                == .app(bundle: "com.example.thing", container: .data))
            assert(parse("fila://app?bundle=../../etc") == nil)
            assert(parse("fila://app") == nil)
            assert(parse("fila://apps") == .installedApps)
            assert(parse("fila://settings") == .settings)

            // The leftmost value is the one that acts.
            assert(parse("fila://open?path=/etc&path=/System") == .directory("/etc"))
        }
    }
#endif
