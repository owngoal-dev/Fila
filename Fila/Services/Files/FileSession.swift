import FilaClient
import FilaLog
import FilaProtocol
import Foundation

/// The app's shared file backend session, using either the daemon or the local
/// service selected by `DaemonLink`.
///
/// One link for the whole process, not one per screen: `jobEvents` is a single
/// stream on the connection, a job outlives the screen that started it, and a
/// second connection would give a second daemon-side listing budget for no gain.
@MainActor
final class FileSession {
    static let shared = FileSession()

    let link = DaemonLink()
    private(set) lazy var operations = OperationCenter(session: self)

    /// The handshake, once one has landed. Nil means it has not — which is
    /// *connecting*, never a failure: `filad` is on-demand and a miss only
    /// means launchd has not spawned it yet.
    ///
    /// The one fact that says the daemon has answered. The task below is not
    /// that fact: it may be a forever wait still going round.
    private(set) var hello: DaemonLink.Hello?

    /// The prefix the daemon resolved for itself. Derived, so it cannot say
    /// "connected" while `hello` says otherwise.
    var installRoot: String? { hello?.installRoot }

    private var handshake: Task<DaemonLink.Hello, Never>?
    private let temporaryIdentifier = UUID().uuidString
    private var temporaryPreparation: Task<URL, Error>?

    private init() {}

    /// Waits for a backend, retrying forever. It cannot throw on purpose:
    /// there is nothing a user could do about a daemon that has not started, so
    /// there is nothing to report.
    ///
    /// "Forever" is still forever on a device with `filad` installed — the loop
    /// below is unchanged for that case. What ends it in the `.tipa`, the
    /// `.ipa` and the simulator is `DaemonLink.hello()` answering with the
    /// in-process backend instead of throwing, which it does only when no
    /// daemon is installed to wait for. See the rule written out there.
    @discardableResult
    func ready() async -> DaemonLink.Hello {
        if let handshake { return await handshake.value }
        let task = Task { () -> DaemonLink.Hello in
            while true {
                if let hello = await self.shakeHands() { return hello }
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
    func ready(within seconds: Double) async -> DaemonLink.Hello? {
        // Already answered: no round trip, and above all no `await` on the
        // handshake task, which may be the forever wait still going round —
        // awaiting that is exactly the wait this exists to avoid.
        if let hello { return hello }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let hello = await shakeHands() { return hello }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return nil
    }

    /// One handshake attempt, and the only place its result is recorded.
    private func shakeHands() async -> DaemonLink.Hello? {
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
        // A bounded wait that got there first spares the forever wait a second
        // round trip — and answers `ready()` immediately for everything after.
        if handshake == nil { handshake = Task { answer } }
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
    func perform<T>(retryOnDisconnect: Bool = false, _ body: (DaemonLink) async throws -> T) async throws -> T {
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
                if attempts < 2 { try await Task.sleep(nanoseconds: 400_000_000) }
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
        guard let hello else { return }
        let workspace = Self.temporaryParent(for: hello.backend).appendingPathComponent(temporaryIdentifier, isDirectory: true)
        do {
            // mobile can empty its private workspace but cannot unlink that
            // directory from the root-owned parent. Startup removes the shell.
            let targets = hello.isPrivileged
                ? try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
                : [workspace]
            for target in targets {
                do { try FileManager.default.removeItem(at: target) }
                catch let error as CocoaError where error.code == .fileNoSuchFile {}
                catch { FilaLog.error("Temporary workspace cleanup failed at \(target.path): \(error)") }
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        catch { FilaLog.error("Temporary workspace cleanup failed: \(error)") }
    }

    private static func temporaryParent(for backend: DaemonLink.Backend) -> URL {
        switch backend {
        case let .daemon(installRoot):
            return URL(fileURLWithPath: installRoot.isEmpty ? "/" : installRoot, isDirectory: true)
                .resolvingSymlinksInPath().appendingPathComponent(".fila-tmp", isDirectory: true)
        case .local:
            return FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wiki.qaq.fila", isDirectory: true)
        }
    }

    private func prepareTemporaryWorkspace() async throws -> URL {
        let hello = await ready()
        try Task.checkCancellation()
        let parent = Self.temporaryParent(for: hello.backend)
        if hello.isPrivileged {
            // The fixed parent keeps mkdir's root ownership and 0755 mode.
            // Only UUID workspaces need an ownership change, so a kill between
            // create and chown leaves a disposable child, not a poisoned root.
            do { try await link.create(.directory, at: parent.path) }
            catch let failure as FilaFailure where failure.systemError == EEXIST {}
        } else if mkdir(parent.path, 0o700) != 0, errno != EEXIST {
            throw FilaFailure(errno: errno, path: parent.path)
        }
        let details = try await link.details(of: parent.path)
        // An existing symlink or somebody else's directory is not ours to
        // adopt, chmod or clean. Private bytes live only in the 0700 child.
        let owner = hello.isPrivileged ? 0 : getuid()
        let mode: mode_t = hello.isPrivileged ? 0o755 : 0o700
        guard details.node.kind == .directory, details.node.ownerID == owner, details.node.mode & 0o777 == mode,
              URL(fileURLWithPath: details.path).standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw FilaFailure(code: .notPermitted, systemError: EPERM, path: parent.path)
        }
        // Finish this one directory's listing before removing its children;
        // deleting during pagination can change which entries a cursor sees.
        let entries = try await DirectoryReader.entries(in: parent.path, session: self)
        try Task.checkCancellation()
        let stale = entries.filter { $0.kind == .directory && UUID(uuidString: $0.name) != nil }
            .map { parent.appendingPathComponent($0.name).path }
        if !stale.isEmpty {
            let outcome = try await operations.awaitJob(JobRequest(kind: .delete, sources: stale), kind: .delete, subtitle: parent.path, feedback: .silent)
            guard outcome.code == .success else { throw outcome }
        }
        try Task.checkCancellation()
        let workspace = parent.appendingPathComponent(temporaryIdentifier, isDirectory: true)
        if hello.isPrivileged {
            try await link.create(.directory, at: workspace.path)
            do {
                try await link.setAttributes(AttributeChange(mode: 0o700, ownerID: getuid(), groupID: getgid()), at: workspace.path)
                try Task.checkCancellation()
            } catch {
                await discardTemporary(workspace.path)
                throw error
            }
        } else {
            guard mkdir(workspace.path, 0o700) == 0 else { throw FilaFailure(errno: errno, path: workspace.path) }
        }
        #if DEBUG
            let privateDirectory = try await link.details(of: workspace.path)
            assert(privateDirectory.node.kind == .directory && privateDirectory.node.ownerID == getuid())
            assert(privateDirectory.node.mode & 0o777 == 0o700)
            assert(URL(fileURLWithPath: privateDirectory.path).deletingLastPathComponent().path == parent.path)
        #endif
        return workspace
    }

    /// A failed publication still owns its adjacent temporary. Wait for the
    /// delete result before returning the original failure to the caller.
    func discardTemporary(_ path: String) async {
        do {
            let outcome = try await operations.awaitJob(JobRequest(kind: .delete, sources: [path]), kind: .delete, subtitle: path, feedback: .silent)
            if outcome.code != .success && outcome.code != .notFound { throw outcome }
        } catch { FilaLog.error("Temporary file cleanup failed at \(path): \(error)") }
    }

    // MARK: - Bytes

    /// Reads at most `limit` bytes of a file through a descriptor the daemon
    /// opened as root. The bytes never touch the daemon — see the descriptor
    /// rule in `Documentation/Architecture.md`.
    func read(_ path: String, limit: Int = .max) async throws -> Data {
        let descriptor = try await perform(retryOnDisconnect: true) { try await $0.open(path, flags: O_RDONLY) }
        return try await Task.detached { try DescriptorIO.readAndClose(descriptor, limit: limit) }.value
    }

    /// Copies through a descriptor into the app's temporary workspace. The
    /// consumer owns the returned file's parent directory until completion.
    func stage(_ path: String) async throws -> URL {
        let directory = try await makeTemporaryDirectory()
        let target = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        do {
            let descriptor = try await perform(retryOnDisconnect: true) { try await $0.open(path, flags: O_RDONLY | O_NONBLOCK) }
            try await Task.detached { try DescriptorIO.copyAndClose(descriptor, to: target) }.value
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
