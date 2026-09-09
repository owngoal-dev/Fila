import Darwin
import FilaLog
import FilaProtocol
import Foundation

/// Where local answers are coming from. An enum with the install root inside
/// it rather than a flag beside it, so a caller cannot read the polarity
/// backwards and report a bootstrap prefix that does not exist.
public enum LocalBackend: Sendable, Equatable {
    /// `filad` answered. Every operation runs as root, in another process,
    /// and `installRoot` is the prefix the daemon resolved for itself —
    /// empty on a rootful layout, `/var/jb` on rootless, a randomized
    /// directory on roothide.
    case daemon(installRoot: String)
    /// There is no daemon here, and there is not going to be one. Every
    /// operation runs in this process as whoever the app is — `mobile`, or
    /// less. `FilaGuard` still refuses what it refuses.
    case local(reach: LocalReach)
}

/// How much of the filesystem this process can reach without a daemon.
///
/// It is the difference between the two unprivileged wrappers and it is not
/// a detail: a TrollStore `.tipa` runs unsandboxed and browses most of the
/// device read-only, while a sideloaded `.ipa` sees its own container and
/// nothing else. Telling the first user they can only see this app's files
/// would read as the app being broken.
public enum LocalReach: Sendable, Equatable {
    /// Sandboxed: this app's own container, and whatever the user hands it.
    case container
    /// Unsandboxed: whatever the user the app runs as can read, which on a
    /// device is most of the filesystem and very little of it writable.
    case user
}

/// The handshake's answer: which side of the file layer is talking.
public struct LocalHello: Sendable {
    public let protocolVersion: UInt64
    public let backend: LocalBackend

    public init(protocolVersion: UInt64, backend: LocalBackend) {
        self.protocolVersion = protocolVersion
        self.backend = backend
    }

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

    public init(entries: [FileNode], cursor: UInt64) {
        self.entries = entries
        self.cursor = cursor
    }

    public var isFinal: Bool {
        cursor == 0
    }
}

public struct JobUpdate: Sendable {
    public let identifier: UInt64
    public let event: JobEvent

    public init(identifier: UInt64, event: JobEvent) {
        self.identifier = identifier
        self.event = event
    }
}

public struct SearchUpdate: Sendable {
    public let identifier: UInt64
    public let batch: SearchBatch

    public init(identifier: UInt64, batch: SearchBatch) {
        self.identifier = identifier
        self.batch = batch
    }
}

/// The two unsolicited streams a local file layer reports on, built once and
/// shared between whoever produces into them and whoever reads them.
///
/// A privileged link builds one of these before it knows which side will
/// answer, hands it to both candidate services, and exposes the read side
/// as its own — the app starts reading job events before the handshake has
/// chosen. A standalone in-process service builds its own.
public struct FileEventStreams: Sendable {
    /// Progress and completion for every running job, in arrival order.
    ///
    /// One stream for all jobs rather than one per job: they arrive on a
    /// single connection, a job outlives the screen that started it, and the
    /// task list wants them all anyway.
    public let jobEvents: AsyncStream<JobUpdate>

    /// Matches from every running search job, in arrival order.
    ///
    /// Separate from `jobEvents` because the two carry different things: a
    /// job event is lifecycle and the newest one supersedes the last, while a
    /// batch of matches is content and dropping one loses results the user
    /// will never see. So this stream is unbounded — which it can afford to
    /// be, because `FilaProtocol.searchResultLimit` bounds a search at about
    /// 160 batches however long it runs.
    ///
    /// One stream for every search, and an `AsyncStream` has one iterator, so
    /// the consumer is a single long-lived reader that fans batches out by
    /// identifier — not a `for await` per search screen. Until something
    /// reads it, batches accumulate here: whatever owns it must start
    /// consuming before the first search does.
    public let searchResults: AsyncStream<SearchUpdate>

    private let events: AsyncStream<JobUpdate>.Continuation
    private let matches: AsyncStream<SearchUpdate>.Continuation

    public init() {
        var events: AsyncStream<JobUpdate>.Continuation!
        jobEvents = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { events = $0 }
        self.events = events

        var matches: AsyncStream<SearchUpdate>.Continuation!
        searchResults = AsyncStream(bufferingPolicy: .unbounded) { matches = $0 }
        self.matches = matches
    }

    public func yield(_ update: JobUpdate) {
        events.yield(update)
    }

    public func yield(_ update: SearchUpdate) {
        matches.yield(update)
    }

    /// Ends both streams. Called by whoever owns the streams when it goes
    /// away, so a reader is not left awaiting a producer that no longer
    /// exists.
    public func finish() {
        events.finish()
        matches.finish()
    }
}

/// Everything the app can ask a local filesystem for, and the contract both
/// answers are written against.
///
/// `LocalFileService` does the work in this process, as whoever the app is
/// running as. The privileged module's link sends the same requests to
/// `filad` over XPC, where they run as root, and falls back to the in-process
/// service when no daemon was installed. They are the same operations because
/// underneath they are the same code: the daemon is a dispatcher over
/// `FilaFileOps`, and so is the local service. Nothing in the file layer —
/// not a `copyfile` call, not the guard, not a path canonicalisation — is
/// written twice.
///
/// This is the *local* contract on purpose: descriptors, POSIX attributes,
/// mount points and job identifiers are what a local filesystem has and a
/// remote one does not. The backend-neutral `FileService` in FilaBackendKit
/// is narrower, and `LocalFileServiceAdapter` maps this onto it.
public protocol LocalFileAccess: AnyObject, Sendable {
    /// Progress and completion for every running job. See `FileEventStreams`.
    var jobEvents: AsyncStream<JobUpdate> { get }
    /// Matches from every running search job. See `FileEventStreams`.
    var searchResults: AsyncStream<SearchUpdate> { get }

    /// The connection to the other process went away, and with it every job
    /// that process was running for us. Set once, before the first request;
    /// it may fire more than once for one disconnection, so what it does
    /// must be idempotent. An in-process service never calls it.
    var onLinkLost: (@Sendable () -> Void)? { get set }

    /// Which side answers, and whether that side is root.
    func hello() async throws -> LocalHello

    func list(directory: String, cursor: UInt64) async throws -> DirectoryPage
    func closeDirectory(cursor: UInt64) async throws
    func details(of path: String) async throws -> FileDetails

    /// A descriptor opened for us — as root by the daemon, or as ourselves.
    /// **The caller owns it and must `close(2)` it** — it is a real file
    /// descriptor in this process, and leaking them is how a file manager
    /// runs a browsing session out of them.
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32

    func create(_ template: NodeTemplate, at path: String, mode: mode_t?) async throws

    /// Move or rename one node.
    ///
    /// Pass `exclusive: true` whenever the destination was chosen by looking
    /// for a free name — "Copy 2", an untitled file, anything in the trash.
    /// Without it the rename is POSIX `rename(2)`, which silently destroys
    /// whatever appeared at that name between the look and the call; with it
    /// the kernel does the check and the move together and the collision
    /// comes back as `EEXIST` for the caller to try the next name.
    func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws

    /// Remove one node and never a tree: `rmdir(2)` for a directory the
    /// caller verified is empty, `unlink(2)` for anything else. The kernel
    /// refuses the other kind, and neither follows a symlink. This is the
    /// source cleanup of a move across backends, one verified entry at a
    /// time; a whole tree goes through a `.delete` job.
    func remove(_ path: String, directory: Bool, overrideGuard: Bool) async throws

    /// Change mode, owner, group, times, BSD flags or one extended attribute.
    func setAttributes(_ change: AttributeChange, at path: String) async throws

    /// Put a temporary file the caller has finished writing in place of
    /// `target`, carrying the original's metadata across first.
    ///
    /// This is the only way to save a file. The temporary must be in the
    /// same directory as the target — a `rename(2)` across volumes is not
    /// atomic and is refused.
    func replaceItem(at target: String, withTemporary temporary: String) async throws

    func mountPoints() async throws -> [MountPoint]
    func volumeInfo(for path: String) async throws -> VolumeInfo
    func extendedAttribute(_ name: String, at path: String) async throws -> Data

    /// Returns the job's identifier. Progress arrives on `jobEvents`, and the
    /// job is over when an event for that identifier is `.completed`.
    ///
    /// A `.search` job is started the same way — `JobRequest(kind: .search,
    /// sources: [root], query: …)` — and its matches arrive on
    /// `searchResults` while its progress and completion arrive on
    /// `jobEvents` like any other job's. Stopping a search early is
    /// `cancelJob`.
    func startJob(_ job: JobRequest) async throws -> UInt64
    func cancelJob(_ identifier: UInt64) async throws

    /// The *other* process's log after `sequence`, and the level it should
    /// capture at from now on. Empty when there is no other process: the
    /// app's own lines are already in `FilaLog`.
    func fetchLog(since sequence: UInt64, level: FilaLog.Level) async throws
        -> (records: [FilaLog.Record], dropped: UInt64)

    /// Drop the connection to the other process, if there is one, so the
    /// next request builds a new one. Nothing to do in-process.
    func invalidate()
}

/// The defaults `DaemonLink` used to carry on its methods, kept so the app's
/// call sites — `session.perform { try await $0.list(directory: p) }` — read
/// as they did.
public extension LocalFileAccess {
    func list(directory: String) async throws -> DirectoryPage {
        try await list(directory: directory, cursor: 0)
    }

    func open(_ path: String, flags: Int32) async throws -> Int32 {
        try await open(path, flags: flags, mode: 0o644)
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try await create(template, at: path, mode: nil)
    }

    func rename(_ source: String, to destination: String, exclusive: Bool = false) async throws {
        try await rename(source, to: destination, exclusive: exclusive, overrideGuard: false)
    }

    func remove(_ path: String, directory: Bool) async throws {
        try await remove(path, directory: directory, overrideGuard: false)
    }
}
