import FilaClient
import FilaLog
import FilaProtocol
import Foundation

/// The app's shared file backend session over the local backend the modules
/// registered at launch.
///
/// One link for the whole process, not one per screen: `jobEvents` is a single
/// stream on the connection, a job outlives the screen that started it, and a
/// second connection would give a second daemon-side listing budget for no gain.
@MainActor
final class FileSession {
    static let shared = FileSession()

    /// The local backend from the registry, and the access behind it. With the
    /// privileged module bundled this is its link, which chooses the daemon
    /// or the in-process service at the handshake; without it, the local
    /// module's own in-process access.
    let local: LocalFileBackend
    let link: any LocalFileAccess
    /// The only way to open a terminal. Nil when no privileged module was
    /// bundled — the terminal is then not offered at all.
    let terminalAccess: (any TerminalAccess)?
    private(set) lazy var operations = OperationCenter(session: self)

    /// The handshake, once one has landed. Nil means it has not — which is
    /// *connecting*, never a failure: `filad` is on-demand and a miss only
    /// means launchd has not spawned it yet.
    ///
    /// The one fact that says the daemon has answered. The task below is not
    /// that fact: it may be a forever wait still going round.
    private(set) var hello: LocalHello?

    /// The prefix the daemon resolved for itself. Derived, so it cannot say
    /// "connected" while `hello` says otherwise.
    var installRoot: String? {
        hello?.installRoot
    }

    private var handshake: Task<LocalHello, Never>?
    private let temporaryIdentifier = UUID().uuidString
    private var temporaryPreparation: Task<URL, Error>?

    private init() {
        let registry = BackendComposition.registry
        if let backend = registry.backends.lazy.compactMap({ $0 as? LocalFileBackend }).first {
            local = backend
        } else {
            // No local module bootstrapped. The app cannot browse without one,
            // and hiding that would be worse than a browsable in-process
            // fallback with the failure on record; discovery already logged
            // why the module was refused.
            FilaLog.error("no local backend registered; file operations run in this process")
            local = LocalFileBackend(
                access: LocalFileService(),
                storage: LocalPreferencesDefaults(),
                environment: .init(inboxDirectory: BackendComposition.host.inboxDirectory)
            )
        }
        link = local.access
        terminalAccess = registry.provider(PrivilegedFileAccess.self)
        do { try local.setRecordsVisits(AppPreferences.shared.recordsRecents) }
        catch { FilaLog.error("history policy not applied: \(error)") }
    }

    /// Waits for a backend, retrying forever. It cannot throw on purpose:
    /// there is nothing a user could do about a daemon that has not started, so
    /// there is nothing to report.
    ///
    /// "Forever" is still forever on a device with `filad` installed — the loop
    /// below is unchanged for that case. What ends it in the `.tipa`, the
    /// `.ipa` and the simulator is `LocalFileAccess.hello()` answering with the
    /// in-process backend instead of throwing, which it does only when no
    /// daemon is installed to wait for. See the rule written out there.
    @discardableResult
    func ready() async -> LocalHello {
        if let handshake {
            return await handshake.value
        }
        let task = Task { () -> LocalHello in
            while true {
                if let hello = await self.shakeHands() {
                    return hello
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        handshake = task
        return await task.value
    }

    /// Waits for the daemon, but only for so long. Nil means it did not answer.
    ///
    /// The forever wait above is right for a screen: it can sit there saying
    /// *Connecting…*, and there is nothing a user could do about a daemon
    /// launchd has not spawned yet. A Shortcut has nobody watching it — it has
    /// to answer, and answer wrongly at worst never — and in the sandboxed
    /// `.ipa` and the simulator there is no daemon to wait for at all.
    ///
    /// It does not disturb a forever wait already running: both go through
    /// `shakeHands`, so whichever gets an answer first is the one everything
    /// after it sees.
    func ready(within seconds: Double) async -> LocalHello? {
        // Already answered: no round trip, and above all no `await` on the
        // handshake task, which may be the forever wait still going round —
        // awaiting that is exactly the wait this exists to avoid.
        if let hello {
            return hello
        }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let hello = await shakeHands() {
                return hello
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return nil
    }

    /// One handshake attempt, and the only place its result is recorded.
    private func shakeHands() async -> LocalHello? {
        guard let answer = try? await link.hello() else {
            // Never an error, however long it goes on: `filad` is on-demand and
            // a miss only means launchd has not spawned it yet. Verbose because
            // this is the whole record behind "it just says Connecting…", and
            // it repeats once a second while that is true.
            FilaLog.verbose("daemon not up yet")
            // A connection whose Mach service was never registered is dead for
            // good, so the next attempt has to build a new one.
            link.invalidate()
            return nil
        }
        FilaLog.info(
            answer.isPrivileged
                ? "daemon reached, protocol \(answer.protocolVersion),"
                + " root \"\(answer.installRoot)\""
                : "no daemon installed; file operations run in this process"
        )
        // Recorded before returning, so it is set before *any* caller resumes:
        // several may be waiting on one handshake and the order they wake in is
        // unspecified.
        hello = answer
        // The windows' tab lists load only from here on; their restoration
        // window is measured from this moment, not from launch, because a
        // daemon still being spawned can hold this up for longer than any
        // window is given.
        BrowserTabStore.noteHandshake()
        local.handshakeLanded(answer)
        // A bounded wait that got there first spares the forever wait a second
        // round trip — and answers `ready()` immediately for everything after.
        if handshake == nil {
            handshake = Task { answer }
        }
        return answer
    }

    /// Every daemon call in the app goes through here.
    ///
    /// `retryOnDisconnect` is for reads and reads only. The daemon exits a few
    /// seconds after its last client disconnects, so the first request after an
    /// idle gap can come back `ECONNRESET` — but that means *the reply was
    /// lost*, not that the work did not happen. Retrying a `startJob` would run
    /// the copy twice, and retrying a `replaceItem` that already landed reports
    /// a failed save for a file that saved. Asking again for a listing costs
    /// nothing, so only those ask again.
    func perform<T>(retryOnDisconnect: Bool = false, _ body: (any LocalFileAccess) async throws -> T) async throws -> T {
        await ready()
        // One immediate resend covers the daemon that exited idle; the waits
        // after it cover a daemon launchd is reloading — an upgrade with the
        // app open — which has no Mach service for a moment, so a resend
        // inside that moment fails the same way and a listing says "reset by
        // peer" for a folder that is fine.
        var attempts = retryOnDisconnect ? 3 : 0
        while true {
            do {
                return try await body(link)
            } catch let failure as FilaFailure where attempts > 0 && failure.systemError == ECONNRESET {
                attempts -= 1
                // Ordinary — the daemon exits when idle — but it is what stands
                // between "the folder took a second to open" and a bug report.
                FilaLog.info("read lost to a dropped link, \(attempts) retry(ies) left")
                if attempts < 2 {
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    // MARK: - Temporary Files

    /// Each consumer owns one directory until its download, preview or share
    /// finishes. The process workspace also catches leftovers after a crash.
    func makeTemporaryDirectory() async throws -> URL {
        let workspace = try await prepareTemporaryFiles()
        try Task.checkCancellation()
        let directory = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw FilaFailure(errno: errno, path: directory.path) }
        return directory
    }

    /// Called at launch as well as by consumers, so stale workspaces are
    /// cleaned even when this launch never shares or downloads a file.
    @discardableResult
    func prepareTemporaryFiles() async throws -> URL {
        if temporaryPreparation == nil {
            temporaryPreparation = Task {
                do { return try await prepareTemporaryWorkspace() }
                catch {
                    temporaryPreparation = nil
                    throw error
                }
            }
        }
        return try await temporaryPreparation!.value
    }

    /// Synchronous best effort for applicationWillTerminate. SIGKILL cannot
    /// call this; the next workspace preparation removes old UUID directories.
    func cleanupTemporaryFiles() {
        temporaryPreparation?.cancel()
        let workspace = Self.temporaryParent.appendingPathComponent(temporaryIdentifier, isDirectory: true)
        do { try FileManager.default.removeItem(at: workspace) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        catch { FilaLog.error("Temporary workspace cleanup failed: \(error)") }
    }

    private static var temporaryParent: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("wiki.qaq.fila", isDirectory: true)
    }

    private func prepareTemporaryWorkspace() async throws -> URL {
        _ = await ready()
        try Task.checkCancellation()
        let parent = Self.temporaryParent
        if mkdir(parent.path, 0o700) != 0, errno != EEXIST {
            throw FilaFailure(errno: errno, path: parent.path)
        }
        let details = try await link.details(of: parent.path)
        // Never adopt an unknown directory or follow a replacement symlink.
        guard details.node.kind == .directory, details.node.ownerID == getuid(), details.node.mode & 0o777 == 0o700,
              URL(fileURLWithPath: details.path).standardizedFileURL.path == parent.standardizedFileURL.path
        else {
            throw FilaFailure(code: .notPermitted, systemError: EPERM, path: parent.path)
        }
        // Complete the listing before deleting. Only UUID process workspaces
        // are ours; terminal configuration files in this parent are separate.
        let entries = try await DirectoryReader.entries(in: parent.path, session: self)
        try Task.checkCancellation()
        let stale = entries.filter { $0.kind == .directory && UUID(uuidString: $0.name) != nil }
            .map { parent.appendingPathComponent($0.name).path }
        if !stale.isEmpty {
            // Leftovers from a run that was killed. Worth a line: it is the
            // only sign the previous launch did not exit normally.
            FilaLog.info("sweeping \(stale.count) stale workspace(s) under \(parent.path)")
            let outcome = try await operations.awaitJob(
                JobRequest(kind: .delete, sources: stale),
                kind: .delete,
                subtitle: parent.path,
                feedback: .silent
            )
            guard outcome.code == .success else { throw outcome }
        }
        try Task.checkCancellation()
        let workspace = parent.appendingPathComponent(temporaryIdentifier, isDirectory: true)
        guard mkdir(workspace.path, 0o700) == 0 else { throw FilaFailure(errno: errno, path: workspace.path) }
        return workspace
    }

    /// A failed publication still owns its adjacent temporary. Wait for the
    /// delete result before returning the original failure to the caller.
    func discardTemporary(_ path: String) async {
        do {
            let outcome = try await operations.awaitJob(
                JobRequest(kind: .delete, sources: [path]),
                kind: .delete,
                subtitle: path,
                feedback: .silent
            )
            if outcome.code != .success, outcome.code != .notFound {
                throw outcome
            }
        } catch { FilaLog.error("Temporary file cleanup failed at \(path): \(error)") }
    }

    // MARK: - Bytes

    /// Reads at most `limit` bytes of a file through a descriptor the daemon
    /// opened as root. The bytes never touch the daemon — see the descriptor
    /// rule in `Documentation/Architecture.md`.
    func read(_ path: String, limit: Int) async throws -> Data {
        let descriptor = try await perform(retryOnDisconnect: true) { try await $0.open(path, flags: O_RDONLY) }
        return try await Task.detached { try DescriptorIO.readAndClose(descriptor, limit: limit) }.value
    }

    /// Copies through a descriptor into the app's temporary workspace. The
    /// consumer owns the returned file's parent directory until completion.
    func stage(_ path: String) async throws -> URL {
        let directory = try await makeTemporaryDirectory()
        let target = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        do {
            let descriptor = try await perform(retryOnDisconnect: true) {
                try await $0.open(path, flags: O_RDONLY | O_NONBLOCK)
            }
            try await Task.detached { try DescriptorIO.copyAndClose(descriptor, to: target) }.value
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
