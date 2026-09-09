import Darwin
import FilaFileOps
import FilaFormats
import FilaLog
import FilaProtocol
import Foundation

/// The same operations, performed here, as whoever the app is running as.
///
/// This is what the `.tipa` and the `.ipa` run on, and what the simulator runs
/// on: neither wrapper ships `filad`, and `launchd_sim` cannot register a Mach
/// service for one, so without this the app waits on *Connecting…* forever and
/// never opens a file.
///
/// **There is no second file layer here.** Every call below is the same
/// `FilaFileOps` call the daemon makes, in the same order, with the same
/// arguments — `FileOperations`, `ListingRegistry`, `FileJob`. `filad` is an
/// XPC shell over that module and so is this; a `copyfile` written a second
/// time is a `copyfile` that loses an xattr a second way. If you are about to
/// add file logic to this file, it belongs in `FilaFileOps` instead, where the
/// harness can reach it.
///
/// What differs is the privilege, and nothing else: the syscalls run as
/// `mobile` (or less), so most of the device is readable and very little of it
/// is writable. Failures come back as the real `errno` — `EACCES` where the
/// daemon would have succeeded — which is the honest answer and the one the
/// app already knows how to show.
///
/// One difference is quieter than an `errno` and worth knowing: a copy made
/// here lands owned by the user the app runs as. `copyfile(3)` with
/// `COPYFILE_ALL` carries xattrs, ACLs, flags and mode across but cannot give
/// a file away without root, and it does not fail for trying — so a root-owned
/// file copied by this backend arrives as a `mobile`-owned file with the same
/// contents and mode. Nothing is lost that the user had; the copy is simply
/// theirs.
public final class LocalFileService: LocalFileAccess, @unchecked Sendable {
    /// The guard, the canonicalisation and the POSIX calls — the daemon's
    /// `FileOperations`, with an empty bootstrap root.
    ///
    /// Empty is not a placeholder, it is the truth: `InstallRoot` derives the
    /// prefix from the daemon's own `proc_pidpath`, and there is no daemon
    /// here. Every wrapper that lands on this service is one that was not
    /// installed by a jailbreak, so there is no bootstrap directory to protect
    /// — and `FilaGuard`'s other roots (`/`, `/System`, `/usr`,
    /// `/private/var/mobile` and the rest) are absolute and still enforced.
    ///
    /// Enforced *here*, not in the app: the rule that the guard lives in one
    /// place survives this change, because this is the same code the daemon
    /// runs and the app above it still cannot reach a syscall except through
    /// it. There is no privilege boundary to defend in this process, but the
    /// guard is not only about privilege — an unprivileged `rm -rf` of
    /// `/var/mobile/Library` is still the user's device broken.
    private let operations = FileOperations(bootstrapRoot: "")

    /// One peer's worth of open directory handles — there is exactly one peer.
    /// Touched only on `queue`, like the daemon's copy is touched only on its
    /// control queue.
    private let listings = ListingRegistry()

    /// Requests run here rather than on whatever thread `await` left us on.
    /// Serial for the reason the daemon's control queue is serial: the listing
    /// registry is not thread-safe, and these calls block in the kernel — a
    /// `readdir` of a 100k-entry directory would otherwise sit on a cooperative
    /// thread that Swift concurrency expects back.
    private let queue = DispatchQueue(label: "wiki.qaq.fila.local", qos: .userInitiated)
    /// Jobs, one at a time, off the request queue. Same reasoning as
    /// `DaemonServer`: every job blocks inside `copyfile`/`removefile` for its
    /// whole life and they are all waiting on the same flash device, so a
    /// concurrent queue would buy nothing but threads.
    private let jobQueue = DispatchQueue(label: "wiki.qaq.fila.local.jobs", qos: .utility)
    /// And searches on their own lane, so a paste does not sit at 0% behind a
    /// search of the whole device.
    private let searchQueue = DispatchQueue(label: "wiki.qaq.fila.local.search", qos: .userInitiated)

    /// A `FileJob`, or an `ArchiveJob` for a compress or an extract: with no
    /// daemon there is no helper to spawn, so the archive work runs here, in
    /// the process that would have spawned it.
    private var jobs: [UInt64: any RunningJob] = [:]
    private var nextJobIdentifier: UInt64 = 1

    private let streams: FileEventStreams
    /// Whether this service built its streams, and so ends them when it goes.
    private let ownsStreams: Bool

    public var jobEvents: AsyncStream<JobUpdate> { streams.jobEvents }
    public var searchResults: AsyncStream<SearchUpdate> { streams.searchResults }

    /// Set by `OperationCenter` through the contract and never read here:
    /// there is no connection to lose, and a job cannot die with one. If
    /// this ever grows a reader it needs a lock — the class is
    /// `@unchecked Sendable`.
    public var onLinkLost: (@Sendable () -> Void)?

    /// Probed once, when this service is built, rather than per handshake: it
    /// is a syscall and a log line, the answer cannot change while the process
    /// lives, and `hello()` is asked again by every screen that wants to know
    /// what it is talking to.
    public let reach = LocalFileService.processReach

    /// How far this process can see, before any service is built — what a
    /// module asks to choose its backend.
    ///
    /// The simulator is pinned to the container. Its process is not
    /// sandboxed and could open the Mac's whole filesystem, but no wrapper
    /// of this app ever runs there, and the sandboxed `.ipa` — the one
    /// composition with no other test surface — is what the simulator
    /// stands in for. Everything else asks the filesystem, once: the answer
    /// cannot change while the process lives.
    public static let processReach: LocalReach = {
        #if targetEnvironment(simulator)
            .container
        #else
            probeReach()
        #endif
    }()

    /// A service that owns its streams — what a build with no privileged
    /// module runs on.
    public convenience init() {
        self.init(streams: FileEventStreams(), ownsStreams: true)
    }

    /// A service reporting into streams someone else owns — what the
    /// privileged link falls back to once its grace period is up, so the
    /// events land on the streams the app was already reading.
    public convenience init(streams: FileEventStreams) {
        self.init(streams: streams, ownsStreams: false)
    }

    private init(streams: FileEventStreams, ownsStreams: Bool) {
        self.streams = streams
        self.ownsStreams = ownsStreams
        FilaLog.info("running in-process, reach: \(reach)")
    }

    deinit {
        if ownsStreams {
            streams.finish()
        }
    }

    // MARK: - Requests

    public func hello() async throws -> LocalHello {
        LocalHello(protocolVersion: FilaProtocol.version, backend: .local(reach: reach))
    }

    /// Whether this process can read anything outside its own container.
    ///
    /// The two unprivileged wrappers are very different places to be and the
    /// user is owed the difference: a TrollStore `.tipa` is unsandboxed and
    /// browses most of the device, while a sideloaded `.ipa` sees its container
    /// and nothing else. Telling the first user they can only see this app's
    /// own files would read as the app being broken.
    ///
    /// XPC cannot answer this — a sandbox-denied Mach lookup and a lookup for
    /// an unregistered name are both a connection-invalid error, with the
    /// difference visible only in XPC's own log line — so ask the filesystem
    /// the question we actually mean: open the directory our container sits in,
    /// which the sandbox does not grant and which the app's own user owns. No
    /// hardcoded path, nothing private, and the answer is exactly the claim we
    /// are about to make to the user.
    static func probeReach(container: String = NSHomeDirectory()) -> LocalReach {
        let directory = URL(fileURLWithPath: container, isDirectory: true).deletingLastPathComponent()
        guard let handle = opendir(directory.path) else { return .container }
        closedir(handle)
        return .user
    }

    public func closeDirectory(cursor: UInt64) async throws {
        try await run("closeDirectory") { self.listings.close(cursor: cursor) }
    }

    public func list(directory: String, cursor: UInt64) async throws -> DirectoryPage {
        try await run("list \(directory)") {
            let page = try self.listings.page(directory: directory, cursor: cursor)
            return DirectoryPage(entries: page.entries, cursor: page.cursor)
        }
    }

    public func details(of path: String) async throws -> FileDetails {
        try await run("stat \(path)") { try self.operations.details(of: path) }
    }

    /// A descriptor the caller owns and must close, exactly as when the daemon
    /// opens one — the difference is only who opened it. The bytes were never
    /// going through a message either way.
    public func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try await run("open \(path)") { try self.operations.open(path, flags: flags, mode: mode) }
    }

    public func create(_ template: NodeTemplate, at path: String, mode: mode_t?) async throws {
        try await run("create \(path)") { try self.operations.create(template, at: path, mode: mode) }
    }

    public func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws {
        try await run("rename \(source) → \(destination)") {
            try self.operations.rename(source, to: destination, exclusive: exclusive, overrideGuard: overrideGuard)
        }
    }

    public func remove(_ path: String, directory: Bool, overrideGuard: Bool) async throws {
        try await run("remove \(path)") {
            try self.operations.removeNode(at: path, directory: directory, overrideGuard: overrideGuard)
        }
    }

    public func setAttributes(_ change: AttributeChange, at path: String) async throws {
        try await run("setAttributes \(path)") { try self.operations.setAttributes(change, at: path) }
    }

    public func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await run("replace \(target)") { try self.operations.replaceItem(at: target, withTemporary: temporary) }
    }

    public func mountPoints() async throws -> [MountPoint] {
        try await run("mountPoints") { try self.operations.mountPoints() }
    }

    public func volumeInfo(for path: String) async throws -> VolumeInfo {
        try await run("volumeInfo \(path)") { try self.operations.volumeInfo(for: path) }
    }

    public func extendedAttribute(_ name: String, at path: String) async throws -> Data {
        // The attribute's name, never its bytes: an xattr is a file in disguise.
        try await run("xattr \(name) \(path)") { try self.operations.extendedAttribute(name, at: path) }
    }

    public func startJob(_ job: JobRequest) async throws -> UInt64 {
        try await run("startJob \(job.kind)") {
            let identifier = self.nextJobIdentifier
            self.nextJobIdentifier &+= 1

            let work: any RunningJob = job.kind.isArchive
                ? ArchiveJob(request: job, operations: self.operations)
                : FileJob(request: job, operations: self.operations)
            self.jobs[identifier] = work
            // The same two lines `DaemonServer` writes for the same job, so a
            // log read off the simulator or a `.tipa` says what a log read off
            // a jailbroken device says.
            FilaLog.info(
                "job \(identifier) \(job.kind) \(job.sources.count) source(s)"
                    + " → \(job.destination ?? "-")"
                    + (job.useTrash ? " trash" : "")
                    + (job.overrideGuard ? " override" : "")
            )
            let lane = job.kind == .search ? self.searchQueue : self.jobQueue
            lane.async {
                let outcome = work.run { progress in
                    self.streams.yield(JobUpdate(identifier: identifier, event: .progress(progress)))
                } matches: { batch in
                    self.streams.yield(SearchUpdate(identifier: identifier, batch: batch))
                } note: { line in
                    FilaLog.warning("job \(identifier): \(line)")
                }
                FilaLog.log(
                    FilaLog.level(for: outcome.code),
                    "job \(identifier) \(outcome.path ?? "-") \(FilaLog.describe(outcome))"
                )
                self.streams.yield(JobUpdate(identifier: identifier, event: .completed(outcome)))
                // Dropped after the completion is out, so a cancel that arrives
                // in between still finds the job rather than silently doing
                // nothing.
                self.queue.async { self.jobs[identifier] = nil }
            }
            return identifier
        }
    }

    public func cancelJob(_ identifier: UInt64) async throws {
        try await run("cancelJob \(identifier)") { self.jobs[identifier]?.cancel() }
    }

    /// There is no daemon, so there is no daemon log. The app's own lines are
    /// already in `FilaLog`, where the log screen reads them without asking
    /// anybody.
    public func fetchLog(since _: UInt64, level _: FilaLog.Level) async throws
        -> (records: [FilaLog.Record], dropped: UInt64)
    {
        ([], 0)
    }

    /// Nothing to drop: there is no connection.
    public func invalidate() {}

    // MARK: - Off the caller's thread

    /// Runs one blocking operation on `queue` and hands the result back.
    ///
    /// `withCheckedThrowingContinuation` rather than a `Task.detached`, because
    /// the point is the *serial* queue: the listing registry and the job table
    /// have exactly one owner, the same way they do in the daemon.
    ///
    /// `what` is the line this operation writes at verbose. It is here for the
    /// reason `DaemonFileService.send` logs in one place: this is every request
    /// the local backend serves, so the trace costs three lines rather than one
    /// at each of a dozen call sites — and the two backends then read the same.
    /// The description is built whether or not verbose is on, because the
    /// failure line below is not gated on verbose and a refusal with no subject
    /// is not a log line. One interpolation against a syscall and a queue hop.
    private func run<T>(_ what: String, _ body: @escaping () throws -> T) async throws -> T {
        FilaLog.verbose("→ \(what)")
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try body() })
                }
            }
            FilaLog.verbose("← \(what) ok")
            return value
        } catch let failure as FilaFailure {
            // Not gated on verbose: with no daemon there is no second process
            // writing the refusal down, so this line is the only record of it.
            FilaLog.log(FilaLog.level(for: failure.code), "\(what) \(FilaLog.describe(failure))")
            throw failure
        } catch {
            // Anything that is not a `FilaFailure` — something thrown from
            // underneath `FileOperations` that never became one. Rarer, and for
            // that reason the line worth having most.
            FilaLog.error("\(what) \(error)")
            throw error
        }
    }
}

/// The two shapes a job takes here, seen the one way the table needs.
private protocol RunningJob: Sendable {
    func run(
        report: @escaping (JobProgress) -> Void,
        matches: @escaping (SearchBatch) -> Void,
        note: @escaping (String) -> Void
    ) -> FilaFailure
    func cancel()
}

extension FileJob: RunningJob {}

extension ArchiveJob: RunningJob {
    func run(
        report: @escaping (JobProgress) -> Void,
        matches _: @escaping (SearchBatch) -> Void,
        note: @escaping (String) -> Void
    ) -> FilaFailure {
        run(report: report, note: note)
    }
}
