import FilaClient
import FilaProtocol
import Foundation
import UIKit

/// Everything a Fila intent needs that App Intents does not provide.
///
/// # Why this file does not import AppIntents
///
/// `AppIntents` is iOS 16 and this app runs on iOS 15, so every type that
/// touches the framework sits behind `@available` and is invisible to the
/// compiler on the older OS. What is here — path bounding, reaching the daemon,
/// turning a `FilaFailure` into a sentence — is neither iOS 16 nor App Intents,
/// and keeping it out here means it is type-checked on every OS the app builds
/// for and can be read without knowing the framework at all.
///
/// # An intent is a client of `filad` like any other
///
/// Nothing below reads a directory, opens a file or deletes anything itself.
/// Every one of them asks the daemon, exactly as the browser does, so `FilaGuard`
/// gets its say on the resolved path. An intent that called `FileManager`
/// instead would run as `mobile`, see a different filesystem than the rest of
/// the app, and answer questions about a world the user is not looking at.
enum IntentSupport {
    /// How long a Shortcut waits for `filad` before giving up on it.
    ///
    /// The UI waits forever and says *Connecting…* — right for a screen, wrong
    /// here, because nobody is watching a shortcut and it has to either answer
    /// or fail. Long enough for an on-demand launch after a respring, short
    /// enough that the sandboxed `.ipa` — where the Mach lookup is refused and
    /// no daemon is coming, ever — fails while the user is still looking at it.
    static let daemonWaitSeconds = 6.0

    /// The largest file `ReadTextFileIntent` will turn into a string.
    ///
    /// A Shortcut variable is held whole in memory and shown in a text field;
    /// a megabyte is already past what anyone reads. Bigger is not truncated,
    /// it is refused — half a config file that looks like the whole one is
    /// worse than an error.
    static let textByteLimit = 1_024 * 1_024

    /// The most entries `ListDirectoryIntent` will hand back.
    ///
    /// Also not a truncation: a directory with more than this fails and says
    /// so. A shortcut cannot tell a capped list from a complete one, and a
    /// script that thinks it has seen every file in a folder is a script that
    /// will act on that belief.
    static let listEntryLimit = 10_000

    // MARK: - Paths

    /// Bounds and canonicalises a path a shortcut supplied.
    ///
    /// The same `FilaLink.canonical` the URL scheme uses, for the same reason
    /// and with the same caveat: it is lexical, and the daemon canonicalises
    /// with `realpath(3)` and runs `FilaGuard` on whatever finally reaches it.
    /// This layer exists so a path that is not a path is refused with a
    /// sentence rather than travelling any further.
    static func path(_ raw: String) throws -> String {
        guard let path = FilaLink.canonical(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IntentFailure.invalidPath(raw)
        }
        return path
    }

    /// A directory path joined to a name, with the name refused if it is one.
    ///
    /// A shortcut builds names out of variables, so `name` is whatever the last
    /// action produced: a separator or a `..` in it would make "create a folder
    /// in Documents" create one anywhere on the device. The join is a join, not
    /// a path expression.
    static func child(of directory: String, named name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw IntentFailure.invalidName(name)
        }
        return try path(directory == "/" ? "/" + name : directory + "/" + name)
    }

    // MARK: - The daemon

    /// The session, once `filad` has answered — or a failure that says it has
    /// not.
    @MainActor
    static func session() async throws -> FileSession {
        let session = FileSession.shared
        guard await session.ready(within: daemonWaitSeconds) != nil else {
            throw IntentFailure.noDaemon
        }
        return session
    }

    /// One request to the daemon, with its refusal turned into something a
    /// shortcut can show.
    @MainActor
    static func daemon<T>(
        retryOnDisconnect: Bool = false,
        _ body: (DaemonLink) async throws -> T
    ) async throws -> T {
        let session = try await session()
        do {
            return try await session.perform(retryOnDisconnect: retryOnDisconnect, body)
        } catch let failure as FilaFailure {
            throw IntentFailure.refused(failure)
        }
    }

    /// `lstat` and the rest, for one path. The one place an intent learns what
    /// a path actually is.
    @MainActor
    static func details(of path: String) async throws -> FileDetails {
        try await daemon(retryOnDisconnect: true) { try await $0.details(of: path) }
    }

    /// The same, except that "there is nothing at this path" comes back as nil
    /// instead of as a failure. Every other refusal is still a failure — the
    /// distinction is the whole point of the call.
    @MainActor
    static func absentOrDetails(of path: String) async throws -> FileDetails? {
        let session = try await session()
        do {
            return try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
        } catch let failure as FilaFailure where failure.systemError == ENOENT {
            return nil
        } catch let failure as FilaFailure {
            throw IntentFailure.refused(failure)
        }
    }

    /// Runs a body, turning the daemon's refusal into a sentence a shortcut can
    /// show. For the calls that do not go through `daemon(_:)` — the ones that
    /// stream, or that go through the app's own writer.
    static func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as FilaFailure {
            throw IntentFailure.refused(failure)
        }
    }

    /// Starts a daemon job and waits for it to finish, failing when it failed.
    ///
    /// Through `OperationCenter`, never straight to the daemon: `jobEvents` has
    /// one consumer in this process and that is it, so a job started behind its
    /// back would run with nobody listening for its completion. It also means
    /// work a shortcut started appears in the transfers list, where the user
    /// can watch it and stop it, which is where work that changes their
    /// filesystem belongs whoever asked for it.
    @MainActor
    static func job(
        _ request: JobRequest,
        kind: OperationCenter.Kind,
        subtitle: String,
        announcing directories: [String]
    ) async throws {
        let session = try await session()
        let outcome = try await mapping {
            try await session.operations.awaitJob(request, kind: kind, subtitle: subtitle)
        }
        guard outcome.code == .success else { throw IntentFailure.refused(outcome) }
        // The job announced the directories *it* worked on, which are the
        // daemon's resolved spellings — `/private/var/mobile/…`. A browser
        // matches on the string it was opened with, which is lexical, so the
        // folder the user is actually looking at is told here, under the name
        // they are looking at it by.
        announceChange(in: directories)
    }

    /// Resolves a copy or a move: the source, the destination directory, and
    /// where the item will land.
    ///
    /// Both come back as the daemon spells them — `realpath(3)`, so
    /// `/var/mobile` reads `/private/var/mobile` — because the confirmation
    /// prompt has to name the place that will actually be written, not the
    /// string the shortcut typed. Resolving also settles that the destination
    /// exists and is a directory, which is the difference between a prompt
    /// about a real move and a prompt about one that cannot happen.
    @MainActor
    static func transfer(_ source: String, into destination: String)
        async throws -> (source: String, destination: String, landing: String) {
        let source = try await details(of: try path(source)).path
        let folder = try await details(of: try path(destination))
        guard folder.node.isNavigable else { throw IntentFailure.notADirectory(folder.path) }
        let name = (source as NSString).lastPathComponent
        let landing = folder.path == "/" ? "/" + name : folder.path + "/" + name
        return (source, folder.path, landing)
    }

    /// Tells the browsers that something under these directories changed.
    ///
    /// A daemon job announces itself through `OperationCenter`; a single round
    /// trip an intent made does not, and a browser sitting on that directory
    /// would go on showing the file the shortcut just wrote over.
    static func announceChange(in directories: [String]) {
        NotificationCenter.default.post(name: .filaJobFinished, object: directories)
    }

    // MARK: - Navigating

    /// Sends a `fila://` link through the app's own router.
    ///
    /// A navigating intent asks for a URL and hands it to `LinkRouting`, which
    /// already decides where every verb lands. Two things fall out of that.
    /// One: a link and a shortcut cannot drift apart about what "reveal" means,
    /// because there is one router. Two — and this is the one worth writing
    /// down — **an intent can only ask for something the read-only parser
    /// accepts.** The URL is built and then parsed back, so a verb that does
    /// not exist in `FilaLink` cannot be navigated to from here either.
    ///
    /// Handed to the router in-process rather than to `UIApplication.open`.
    /// Opening our own scheme would leave the system to route it, and the
    /// system asks the user to confirm opening an app — a second prompt, on top
    /// of the launch the intent already caused, for the app they are already
    /// looking at.
    ///
    /// The wait is for the window. `openAppWhenRun` brings the app up, but on a
    /// cold launch the scene is still connecting while `perform` runs, and
    /// there is nothing to push onto yet.
    @MainActor
    static func navigate(_ verb: String, _ values: [String: String]) async throws {
        var components = URLComponents()
        components.scheme = FilaLink.scheme
        components.host = verb
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, FilaLink(url) != nil else {
            throw IntentFailure.invalidPath(values["path"] ?? verb)
        }
        for _ in 0 ..< 20 {
            if let root = rootController {
                root.follow(url)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntentFailure.noWindow
    }

    /// The split view the app is built around, if a scene has one up.
    @MainActor
    private static var rootController: RootSplitViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController as? RootSplitViewController }
            .first
    }
}

/// Why an intent could not answer.
///
/// A sentence and nothing else, deliberately. Every one of these ends the same
/// way — App Intents shows `errorDescription` and the shortcut stops — so there
/// is nothing for a caller to switch on and no case list to keep in step with
/// one. What the type is for is keeping the sentences together, where they can
/// be read as a set and found by whoever translates them.
///
/// A `LocalizedError` because that is what App Intents displays. No framework
/// type is involved, which is what lets this file compile on iOS 15.
struct IntentFailure: LocalizedError {
    let errorDescription: String?

    static func invalidPath(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(path)” is not an absolute path. Enter a path that starts with /."))
    }

    static func invalidName(_ name: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(name)” is not a valid name. Enter a name without slashes, and do not use “.” or “..”."))
    }

    static func invalidBundleIdentifier(_ bundleIdentifier: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(bundleIdentifier)” is not a valid bundle identifier. Enter a different identifier."))
    }

    static func invalidSearch(_ query: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(query)” is not a valid search. Enter the text to find."))
    }

    /// Deliberately not "an error has occurred". In the sandboxed `.ipa` this
    /// is permanent, not a hiccup, and the user needs to know which Fila they
    /// are holding.
    static let noDaemon = IntentFailure(errorDescription: String(
        localized: "Fila could not get root access. Install the Fila .deb on a jailbroken device, or check that the jailbreak is running."
    ))

    static func notAFile(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(path)” is not a file. Choose a file."))
    }

    static func notADirectory(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(path)” is not a folder. Choose a folder."))
    }

    static func notText(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(path)” could not be read as text. Choose a text file."))
    }

    static func tooLarge(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(localized: "“\(path)” is too large to read as text. Choose a smaller file."))
    }

    static func tooManyEntries(_ path: String) -> IntentFailure {
        IntentFailure(errorDescription: String(
            localized: "“\(path)” holds too many items to list. Use the Find Files action instead."
        ))
    }

    static let noWindow = IntentFailure(errorDescription: String(localized: "Fila did not open in time. Try again."))

    /// The daemon said no, in its own words — so that a shortcut and the app
    /// describe the same errno the same way.
    static func refused(_ failure: FilaFailure) -> IntentFailure {
        IntentFailure(errorDescription: FailureText.title(for: failure) + " · " + FailureText.summary(for: failure))
    }
}

#if DEBUG
    extension IntentSupport {
        /// The bounding check, run once at launch in Debug builds.
        ///
        /// Beside `FilaLink.runSelfCheck` and for the same reason: a shortcut
        /// is input from outside the app, this is where it is bounded, the app
        /// target has no test target, and the piece worth checking is pure
        /// logic over strings.
        static func runSelfCheck() {
            assert((try? path("/var/mobile")) == "/var/mobile")
            // Trimmed, and `..` collapsed a component at a time — so this is
            // `/var/etc`, not `/etc`.
            assert((try? path("  /var/mobile/../etc  ")) == "/var/etc")
            assert((try? path("/var/mobile/../../../..")) == "/")
            assert((try? path("var/mobile")) == nil)
            assert((try? path("")) == nil)

            // A name is a name. It is built out of whatever the previous action
            // in the shortcut produced, so a separator or a `..` in it would
            // turn "create a folder in Documents" into "create one anywhere".
            assert((try? child(of: "/var/mobile", named: "Notes")) == "/var/mobile/Notes")
            assert((try? child(of: "/", named: "Notes")) == "/Notes")
            assert((try? child(of: "/var/mobile", named: " Notes ")) == "/var/mobile/Notes")
            assert((try? child(of: "/var/mobile", named: "../../etc")) == nil)
            assert((try? child(of: "/var/mobile", named: "a/b")) == nil)
            assert((try? child(of: "/var/mobile", named: "..")) == nil)
            assert((try? child(of: "/var/mobile", named: ".")) == nil)
            assert((try? child(of: "/var/mobile", named: "")) == nil)
            assert((try? child(of: "/var/mobile", named: "a\0b")) == nil)
        }
    }
#endif
