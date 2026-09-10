import FilaBackendKit
import FilaLog
import Foundation

extension Notification.Name {
    /// A preference changed somewhere other than the screen that renders it —
    /// in practice, the settings screen. Browsers re-read their layout and
    /// re-apply their snapshot; a modal settings screen never triggers the
    /// presenting controller's appearance callbacks, so there is nothing else
    /// that would tell them.
    static let filaPreferencesChanged = Notification.Name("wiki.qaq.fila.preferences")
}

/// Where the browser opens on launch. `AppPreferences.launchDirectory` resolves
/// it — the value is a choice; what was last visited is the local backend's.
///
/// Stored as one string, and a folder stores its own absolute path. The three
/// fixed answers are words and a folder is a path, so the two can never be
/// confused for one another and no second defaults key has to be kept in step
/// with this one.
enum LaunchLocation: RawRepresentable, Equatable {
    case root
    case home
    case lastVisited
    case folder(String)

    init?(rawValue: String) {
        switch rawValue {
        case "root": self = .root
        case "home": self = .home
        case "lastVisited": self = .lastVisited
        default:
            guard rawValue.hasPrefix("/") else { return nil }
            self = .folder(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .root: "root"
        case .home: "home"
        case .lastVisited: "lastVisited"
        case let .folder(path): path
        }
    }
}

/// What the app itself remembers between launches: switches that are the
/// app's policy rather than any one backend's. Bookmarks, history and listing
/// options belong to the backend they describe — see `LocalFileBackend`.
///
/// `UserDefaults` rather than a store of our own: it is a handful of switches
/// and a few strings, it has to survive a respring, and nothing here is worth a
/// file format.
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Browsing

    var launchLocation: LaunchLocation {
        get { defaults.string(forKey: "launchLocation").flatMap(LaunchLocation.init) ?? .lastVisited }
        set { defaults.set(newValue.rawValue, forKey: "launchLocation") }
    }

    /// Where the browser opens.
    ///
    /// `/var/mobile` rather than `NSHomeDirectory()`: the app's own container
    /// is the one directory a root file manager's user is *not* looking for.
    /// Checked rather than assumed, because the Mac development loop has no
    /// such directory and launching into one the daemon cannot list would look
    /// like the daemon being broken.
    var launchDirectory: String {
        let session = FileSession.shared
        if case .local(.container) = session.hello?.backend {
            // A restored external path may have lost its temporary grant.
            // Start at the sandboxed backend's own root; explicit navigation
            // can still ask for other paths and receive the real permission
            // error.
            return session.local.rootPath
        }
        switch launchLocation {
        case .root: return session.local.rootPath
        case .home: return FileManager.default.fileExists(atPath: "/var/mobile") ? "/var/mobile" : session.local.rootPath
        case .lastVisited: return session.lastDirectoryPath
        // Not checked for existence: `mobile` cannot stat every directory root
        // can open, so a check would refuse exactly the folders this file
        // manager exists for. A folder that really is gone fails in the
        // browser, where the error says which path and why.
        case let .folder(path): return path
        }
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

    // MARK: - Scripts

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

    private static var defaultServerRoot: String {
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

    // MARK: - History policy

    /// Whether visits are recorded at all. On by default — the list is the
    /// point of having one — but this is a root file manager, so the trail it
    /// leaves is a list of every sensitive directory its user opened, sitting
    /// in a plist any other root process can read. That is a reason to be able
    /// to say no.
    ///
    /// One policy for every backend: each records its own history and this
    /// switch reaches all of them, offline ones included. Turning it off
    /// clears what is already there — a switch that stops adding but leaves
    /// the history behind has not done what its label says.
    var recordsRecents: Bool {
        get { defaults.object(forKey: "recordsRecents") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "recordsRecents")
            for backend in BackendComposition.fileBackends {
                do { try backend.setRecordsVisits(newValue) }
                catch { FilaLog.error("history policy not applied to \(backend.id): \(error)") }
            }
        }
    }
}
