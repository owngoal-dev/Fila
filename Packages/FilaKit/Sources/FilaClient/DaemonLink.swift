import FilaLog
import FilaProtocol
import Foundation

/// The app's one handle on the file layer, and the only thing that decides
/// which side of it answers.
///
/// Two services sit behind it — `filad` over XPC, or `FilaFileOps` called here
/// in this process — and every call site in the app is written against this
/// type without knowing which one it got. The choice is made once, at the
/// handshake, and never revisited; `Hello.backend` says which way it went and
/// is the only honest answer to "am I running as root".
///
/// The class is a reference type because it owns the streams and the choice; it
/// is safe from any thread because everything it mutates is behind `stateLock`.
public final class DaemonLink: @unchecked Sendable {
    /// Where the answers are coming from. An enum with the install root inside
    /// it rather than a flag beside it, so a caller cannot read the polarity
    /// backwards and report a bootstrap prefix that does not exist.
    public enum Backend: Sendable, Equatable {
        /// `filad` answered. Every operation runs as root, in another process,
        /// and `installRoot` is the prefix the daemon resolved for itself —
        /// empty on a rootful layout, `/var/jb` on rootless, a randomized
        /// directory on roothide.
        case daemon(installRoot: String)
        /// There is no daemon here, and there is not going to be one. Every
        /// operation runs in this process as whoever the app is — `mobile`, or
        /// less. `FilaGuard` still refuses what it refuses.
        case local(reach: Reach)
    }

    /// How much of the filesystem this process can reach without a daemon.
    ///
    /// It is the difference between the two unprivileged wrappers and it is not
    /// a detail: a TrollStore `.tipa` runs unsandboxed and browses most of the
    /// device read-only, while a sideloaded `.ipa` sees its own container and
    /// nothing else. Telling the first user they can only see this app's files
    /// would read as the app being broken.
    public enum Reach: Sendable, Equatable {
        /// Sandboxed: this app's own container, and whatever the user hands it.
        case container
        /// Unsandboxed: whatever the user the app runs as can read, which on a
        /// device is most of the filesystem and very little of it writable.
        case user
    }

    public struct Hello: Sendable {
        public let protocolVersion: UInt64
        public let backend: Backend

        /// The daemon's install prefix, or empty when there is no daemon —
        /// derived from `backend` rather than stored beside it, because two
        /// spellings of one fact is how they end up disagreeing.
        public var installRoot: String {
            guard case let .daemon(root) = backend else { return "" }
            return root
        }

        /// Whether the file layer is running as root.
        public var isPrivileged: Bool {
            guard case .daemon = backend else { return false }
            return true
        }
    }

    /// One page of a directory.
    ///
    /// `cursor` is zero when the listing is finished; anything else goes back
    /// in the next `list` call. The service holds the open directory between
    /// pages, so a page must be asked for reasonably promptly — see
    /// `FilaProtocol.listingIdleTimeoutSeconds`.
    public struct DirectoryPage: Sendable {
        public let entries: [FileNode]
        public let cursor: UInt64

        public var isFinal: Bool { cursor == 0 }
    }

    public struct JobUpdate: Sendable {
        public let identifier: UInt64
        public let event: JobEvent
    }

    public struct SearchUpdate: Sendable {
        public let identifier: UInt64
        public let batch: SearchBatch
    }

    /// Progress and completion for every running job, in arrival order.
    ///
    /// One stream for all jobs rather than one per job: they arrive on a single
    /// connection, a job outlives the screen that started it, and the task list
    /// wants them all anyway. Owned here rather than by either service, because
    /// the app starts reading it before the handshake has chosen one.
    public let jobEvents: AsyncStream<JobUpdate>

    /// Matches from every running search job, in arrival order.
    ///
    /// Separate from `jobEvents` because the two carry different things: a job
    /// event is lifecycle and the newest one supersedes the last, while a batch
    /// of matches is content and dropping one loses results the user will never
    /// see. So this stream is unbounded — which it can afford to be, because
    /// `FilaProtocol.searchResultLimit` bounds a search at about 160 batches
    /// however long it runs.
    ///
    /// One stream for every search, and an `AsyncStream` has one iterator, so
    /// the consumer is a single long-lived reader that fans batches out by
    /// identifier — not a `for await` per search screen. Until something reads
    /// it, batches accumulate here: whatever owns it must start consuming
    /// before the first search does.
    public let searchResults: AsyncStream<SearchUpdate>

    private let events: AsyncStream<JobUpdate>.Continuation
    private let matches: AsyncStream<SearchUpdate>.Continuation
    private let daemon: DaemonFileService
    private let daemonIsInstalled: Bool
    private let stateLock = NSLock()
    private var bound: (any FileService)?
    /// When the first lookup missed. See `graceHasElapsed`.
    private var firstMiss: Date?
    private let grace: TimeInterval

    /// The connection to `filad` went away.
    ///
    /// It matters because of what the daemon does when a peer disconnects: it
    /// cancels every job that peer started. So a lost link is not a delivery
    /// problem to be retried — every running job is already over, and nothing
    /// will ever arrive on `jobEvents` to say so. Without this, a copy that
    /// died with the connection stays on screen at 40% forever, and anything
    /// awaiting one waits forever with it.
    ///
    /// Set it once, before the first request. It is called on the connection's
    /// own queue and may fire more than once for the same disconnection, so
    /// whatever it does must be idempotent.
    ///
    /// Forwarded to the daemon backend, which is the only one that can lose a
    /// link: the in-process backend has no connection to drop, and its jobs
    /// cannot die with one.
    public var onLinkLost: (@Sendable () -> Void)? {
        get { daemon.onLinkLost }
        set { daemon.onLinkLost = newValue }
    }

    public convenience init() {
        self.init(daemonIsInstalled: DaemonInstallation.isInstalled(besideBundleAt: Bundle.main.bundleURL))
    }

    /// `grace` is a seam for the tests and nothing else: the rule being tested
    /// is "long enough for launchd", and a test that had to wait that long to
    /// prove it would be a test nobody runs.
    init(daemonIsInstalled: Bool, grace: TimeInterval = DaemonLink.graceBeforeFallback) {
        self.grace = grace
        var events: AsyncStream<JobUpdate>.Continuation!
        jobEvents = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { events = $0 }
        self.events = events

        var matches: AsyncStream<SearchUpdate>.Continuation!
        searchResults = AsyncStream(bufferingPolicy: .unbounded) { matches = $0 }
        self.matches = matches

        self.daemonIsInstalled = daemonIsInstalled
        daemon = DaemonFileService(events: events, matches: matches)
    }

    // MARK: - Choosing a backend

    /// Asks the daemon, and decides what a silence means.
    ///
    /// This is the one place the backend is chosen, and the rule is deliberately
    /// **not** a timeout. A timeout would be wrong on a device in the way that
    /// matters most: a jailbreak that has just resprung takes a few seconds to
    /// register the Mach service, and an app that gave up on a timer would
    /// silently demote a root file manager to an unprivileged one. The user
    /// would then see an empty `/var/root` and conclude the app is broken
    /// rather than that it is degraded. Getting demoted without being told is
    /// worse than waiting, so we never demote on the clock.
    ///
    /// What separates the cases is not how long the lookup takes but whether a
    /// daemon exists to answer it at all, and that is a fact on disk:
    ///
    /// 1. Ask. If `filad` answers, we are the privileged build, for good. On a
    ///    jailbroken device the lookup itself is what starts the daemon, so a
    ///    registered service answers even from cold; a *failure* here means the
    ///    name is not registered, not that the daemon is slow.
    /// 2. It did not answer. `DaemonInstallation` says whether this copy of the
    ///    app was installed with the daemon beside it — the `.deb` is the only
    ///    wrapper that ships `filad`. If it was, this is a device where the
    ///    service will appear once launchd catches up: keep throwing, and let
    ///    `FileSession` go on retrying and go on saying *Connecting…*
    ///    forever, exactly as before. There is no path from here to an
    ///    unprivileged backend on a machine that has one installed.
    /// 3. It was not: this binary came from TrollStore, a sideloading tool or
    ///    the simulator, none of which ship a daemon. Waiting would be waiting
    ///    for something nobody installed, and the app would sit on
    ///    *Connecting…* until the user gave up — which is what both the `.ipa`
    ///    and the `.tipa` did before this existed. So fall back and say so in
    ///    `Hello.backend`.
    ///
    ///    Not on the *first* miss, though, and the exception is the one case
    ///    where the two halves of this rule disagree: a `.tipa` installed on a
    ///    jailbroken device that also has the `.deb`. The daemon is real there
    ///    and reachable, but it is not beside *this* bundle, so step 2 cannot
    ///    see it — and a lookup that misses while launchd is still catching up
    ///    would demote a root file manager for the life of the process. A few
    ///    misses first cost the wrappers that really have no daemon about two
    ///    seconds of *Connecting…* at launch, once, and cost the jailbroken
    ///    device nothing.
    ///
    /// The asymmetry is the point and it is preserved here: the cost of waiting
    /// too long is a slow launch, the cost of falling back too early is a root
    /// file manager quietly running as `mobile`, and the grace period is sized
    /// for the second. What it is *not* is a count of attempts. A count means
    /// whatever the caller's polling cadence makes it mean — `ready()` asks
    /// once a second and `ready(within:)` four times a second, so the same
    /// three misses were three seconds of grace for one and three quarters of
    /// a second for the other, and a Shortcut run at launch could demote the
    /// app before launchd had finished starting the daemon.
    ///
    /// (XPC does not help here, which is worth writing down so nobody goes
    /// looking again: a sandbox-denied lookup and a lookup for a name nobody
    /// registered both surface as `XPC_ERROR_CONNECTION_INVALID` with no
    /// distinguishing code. The difference is only in XPC's own log line.)
    public func hello() async throws -> Hello {
        if let bound = current() { return try await bound.hello() }
        do {
            let hello = try await daemon.hello()
            bind(daemon)
            return hello
        } catch {
            guard !daemonIsInstalled, graceHasElapsed() else { throw error }
            // Whoever is bound after this, rather than the service just built:
            // two handshakes at once must not end up answering differently.
            return try await bind(LocalFileService(events: events, matches: matches)).hello()
        }
    }

    /// How long a build that shipped no daemon keeps asking before it settles
    /// for working in-process. About two seconds of *Connecting…* in an `.ipa`
    /// or the simulator, paid once per launch — and the same two seconds
    /// however often the caller asks, which is the whole reason it is a
    /// duration and not a count.
    ///
    /// ponytail: a one-way decision, not a promotion. A respring that takes
    /// longer than this still demotes a TrollStore install on a jailbroken
    /// device until the app is relaunched. The upgrade is to keep asking after
    /// the fallback and rebind when the daemon finally answers, which needs the
    /// running jobs to move across with it.
    private static let graceBeforeFallback: TimeInterval = 2.5

    /// True once the grace period has run out. The clock starts at the first
    /// missed lookup rather than at construction: an app launched into the
    /// background could otherwise spend its whole grace period suspended and
    /// wake up already demoted.
    private func graceHasElapsed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let first = firstMiss else {
            firstMiss = Date()
            return false
        }
        return Date().timeIntervalSince(first) >= grace
    }

    /// The service that has been chosen, or the daemon while nothing has been.
    ///
    /// Defaulting to the daemon rather than to the local service is deliberate:
    /// a call that arrives before the handshake must not be the thing that
    /// quietly decides this app is unprivileged.
    ///
    /// What makes that safe is navigation order, not a guarantee: most callers
    /// go through `FileSession.perform`, which awaits `hello()` first, and
    /// the few that hold a `DaemonLink` directly — the viewers, `AtomicSave`,
    /// the properties sheet — are only reachable from a listing that already
    /// forced it. A screen opened at cold launch without one would talk to the
    /// daemon service in a build that has none and get `ECONNRESET` instead of
    /// working locally; the fix then is to await the handshake on that path,
    /// not to default this to local.
    private func service() -> any FileService {
        current() ?? daemon
    }

    private func current() -> (any FileService)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bound
    }

    /// Binds `service` unless something else won the race, and answers whoever
    /// is bound now.
    @discardableResult
    private func bind(_ service: any FileService) -> any FileService {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let bound { return bound }
        bound = service
        return service
    }

    // MARK: - Requests

    public func list(directory: String, cursor: UInt64 = 0) async throws -> DirectoryPage {
        try await service().list(directory: directory, cursor: cursor)
    }

    public func details(of path: String) async throws -> FileDetails {
        try await service().details(of: path)
    }

    /// A descriptor opened for us — as root by the daemon, or as ourselves.
    /// **The caller owns it and must `close(2)` it** — it is a real file
    /// descriptor in this process, and leaking them is how a file manager runs
    /// a browsing session out of them.
    public func open(_ path: String, flags: Int32, mode: mode_t = 0o644) async throws -> Int32 {
        try await service().open(path, flags: flags, mode: mode)
    }

    public func create(_ template: NodeTemplate, at path: String) async throws {
        try await service().create(template, at: path)
    }

    /// Move or rename one node.
    ///
    /// Pass `exclusive: true` whenever the destination was chosen by looking
    /// for a free name — "Copy 2", an untitled file, anything in the trash.
    /// Without it the rename is POSIX `rename(2)`, which silently destroys
    /// whatever appeared at that name between the look and the call; with it
    /// the kernel does the check and the move together and the collision comes
    /// back as `EEXIST` for the caller to try the next name.
    public func rename(
        _ source: String,
        to destination: String,
        exclusive: Bool = false,
        overrideGuard: Bool = false
    ) async throws {
        try await service().rename(source, to: destination, exclusive: exclusive, overrideGuard: overrideGuard)
    }

    /// Change mode, owner, group, times, BSD flags or one extended attribute.
    ///
    /// **`overrideGuard` does nothing here, and there is nothing for it to do.**
    /// Neither service consults `FilaGuard` for an attribute change and neither
    /// is going to start: the guard's rule is that a protected node may not be
    /// deleted, moved away or replaced, and a chmod does none of the three —
    /// the node is still there afterwards, and editing the files inside
    /// `/System` is the entire point of the app. The parameter is here because
    /// callers already pass it and removing it would churn them; do not read it
    /// as protection that exists.
    public func setAttributes(_ change: AttributeChange, at path: String, overrideGuard _: Bool = false) async throws {
        try await service().setAttributes(change, at: path)
    }

    /// Put a temporary file the caller has finished writing in place of
    /// `target`, carrying the original's metadata across first.
    ///
    /// This is the only way to save a file. The temporary must be in the same
    /// directory as the target — a `rename(2)` across volumes is not atomic and
    /// is refused.
    public func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await service().replaceItem(at: target, withTemporary: temporary)
    }

    public func mountPoints() async throws -> [MountPoint] {
        try await service().mountPoints()
    }

    public func volumeInfo(for path: String) async throws -> VolumeInfo {
        try await service().volumeInfo(for: path)
    }

    public func extendedAttribute(_ name: String, at path: String) async throws -> Data {
        try await service().extendedAttribute(name, at: path)
    }

    /// Returns the job's identifier. Progress arrives on `jobEvents`, and the
    /// job is over when an event for that identifier is `.completed`.
    ///
    /// A `.search` job is started the same way — `JobRequest(kind: .search,
    /// sources: [root], query: …)` — and its matches arrive on `searchResults`
    /// while its progress and completion arrive on `jobEvents` like any other
    /// job's. Stopping a search early is `cancelJob`.
    public func startJob(_ job: JobRequest) async throws -> UInt64 {
        try await service().startJob(job)
    }

    /// A terminal number scoped to the connection that opened it. A reconnect
    /// must not turn an old close request into a request for a new process.
    public struct TerminalIdentifier: Sendable {
        let value: UInt64
        // Older daemons have no owner field; they cannot confirm completion.
        let owner: String?
    }

    /// A pseudo-terminal with a program already running on it.
    public struct Terminal: Sendable {
        public let identifier: TerminalIdentifier
        /// The pseudo-terminal master. **The caller owns it and must `close(2)`
        /// it.** Everything the program prints and everything the user types
        /// travels through this descriptor between the app and the kernel; the
        /// daemon kept no copy and sees none of it.
        public let descriptor: Int32
        /// What was actually exec'd, resolved.
        public let executable: String
        /// Who it runs as — the daemon's answer, not the request. Zero for a
        /// root session; `mobile`'s uid for one the daemon dropped. The UI
        /// reads this rather than assuming, because telling someone a shell is
        /// root when it is not, or that it is not when it is, are both mistakes
        /// nobody can see until it is too late.
        public let userIdentifier: UInt32

        public var isRoot: Bool { userIdentifier == 0 }
    }

    /// Open a terminal on `executable`, on `dpkg -i package` (root only), or on
    /// the login shell the daemon picks when both are nil, as one of the two
    /// users `TerminalUser` names.
    ///
    /// There is deliberately no way to pass arguments or an environment: the
    /// daemon composes both. `user` is not a uid and cannot be made into one —
    /// see `TerminalUser`. See `FilaOperation.openTerminal`.
    public func openTerminal(
        executable: String? = nil,
        package: String? = nil,
        user: TerminalUser,
        workingDirectory: String? = nil,
        columns: UInt16,
        rows: UInt16
    ) async throws -> Terminal {
        // Straight to the daemon, and only when the daemon is what answers.
        // Without one there is no terminal to open: a `forkpty` in this process
        // would run a shell as whoever the app is, which is not what a root
        // file manager's terminal is for, and pretending otherwise would be
        // worse than refusing.
        //
        // The question is which backend is *bound*, not whether a daemon was
        // installed beside the bundle when this was constructed. Those differ
        // in the case that matters: a build with no daemon of its own that
        // spent its grace period missing and settled on the local backend
        // still has `daemonIsInstalled == false`, and one whose daemon never
        // answered would otherwise send this into a connection nothing is
        // listening on and wait there.
        guard try await hello().isPrivileged else {
            throw FilaFailure(code: .notPermitted, path: executable ?? package)
        }
        let reply = try await daemon.send(.openTerminal) { request in
            if let executable { xpc_dictionary_set_string(request, FilaWireKey.path, executable) }
            if let package { xpc_dictionary_set_string(request, FilaWireKey.package, package) }
            if let workingDirectory {
                xpc_dictionary_set_string(request, FilaWireKey.workingDirectory, workingDirectory)
            }
            xpc_dictionary_set_int64(request, FilaWireKey.terminalUser, user.rawValue)
            xpc_dictionary_set_uint64(request, FilaWireKey.columns, UInt64(columns))
            xpc_dictionary_set_uint64(request, FilaWireKey.rows, UInt64(rows))
        }
        let identifier = TerminalIdentifier(
            value: xpc_dictionary_get_uint64(reply, FilaWireKey.terminalIdentifier),
            owner: xpc_dictionary_get_string(reply, FilaWireKey.terminalOwner).map { String(cString: $0) }
        )
        let descriptor = xpc_dictionary_dup_fd(reply, FilaWireKey.descriptor)
        guard descriptor >= 0, identifier.value != 0,
              let program = xpc_dictionary_get_string(reply, FilaWireKey.path),
              let user = xpc_dictionary_get_value(reply, FilaWireKey.userIdentifier),
              xpc_get_type(user) == XPC_TYPE_UINT64,
              let userIdentifier = UInt32(exactly: xpc_uint64_get_value(user)) else {
            // The daemon said yes and a process is already running as root.
            // Failing to make sense of the reply is no reason to leave it
            // there — it would hold a session slot until the app quit.
            if descriptor >= 0 { close(descriptor) }
            if identifier.value != 0 { _ = try? await closeTerminal(identifier) }
            throw FilaFailure(code: .operationFailed, path: executable ?? package)
        }
        return Terminal(
            identifier: identifier,
            descriptor: descriptor,
            executable: String(cString: program),
            userIdentifier: userIdentifier
        )
    }

    /// Hang a terminal up. Closing the master is what the tty layer notices;
    /// this is what makes sure of a program that ignored the `SIGHUP` it sent.
    /// Returns true only when the daemon no longer owns the direct child.
    /// False is a termination request, not proof that input can be removed.
    @discardableResult
    public func closeTerminal(_ identifier: TerminalIdentifier) async throws -> Bool {
        let reply = try await daemon.send(.closeTerminal) { request in
            xpc_dictionary_set_uint64(request, FilaWireKey.terminalIdentifier, identifier.value)
            if let owner = identifier.owner { xpc_dictionary_set_string(request, FilaWireKey.terminalOwner, owner) }
        }
        return identifier.owner != nil && xpc_dictionary_get_bool(reply, FilaWireKey.terminalExited)
    }

    public func cancelJob(_ identifier: UInt64) async throws {
        try await service().cancelJob(identifier)
    }

    /// The daemon's log lines after `sequence`, and the level it should capture
    /// at from now on.
    ///
    /// Polled by the log screen while it is on screen and by nothing else, so
    /// the daemon pays for this only when someone is looking. `dropped` counts
    /// the lines its ring evicted since it started: a caller that sees the
    /// number grow between polls knows it missed some rather than being handed
    /// a log with a silent hole in it.
    ///
    /// Empty with no daemon, and that is the honest answer: there is no second
    /// process, so there is no second log. The app's own lines are already in
    /// `FilaLog` and the log screen reads them from there.
    public func fetchLog(
        since sequence: UInt64,
        level: FilaLog.Level
    ) async throws -> (records: [FilaLog.Record], dropped: UInt64) {
        try await service().fetchLog(since: sequence, level: level)
    }

    /// Drop the connection. Always the daemon's, because it is the only one
    /// that has one: an XPC connection whose Mach service was not registered is
    /// invalid for good, so the retry loop in `FileSession` has to build a
    /// new one rather than resend on the dead one. There is nothing to drop
    /// once the local backend is bound, and nothing calls this then.
    public func invalidate() {
        daemon.invalidate()
    }

    deinit {
        events.finish()
        matches.finish()
    }
}
