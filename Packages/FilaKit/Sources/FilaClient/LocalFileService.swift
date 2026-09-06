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
final class LocalFileService: FileService, @unchecked Sendable {
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

    private let events: AsyncStream<DaemonLink.JobUpdate>.Continuation
    private let matches: AsyncStream<DaemonLink.SearchUpdate>.Continuation

    /// Probed once, when this service is built, rather than per handshake: it
    /// is a syscall and a log line, the answer cannot change while the process
    /// lives, and `hello()` is asked again by every screen that wants to know
    /// what it is talking to.
    private let reach = LocalFileService.probeReach()

    init(
        events: AsyncStream<DaemonLink.JobUpdate>.Continuation,
        matches: AsyncStream<DaemonLink.SearchUpdate>.Continuation
    ) {
        self.events = events
        self.matches = matches
        FilaLog.info("no daemon installed; running in-process, reach: \(reach)")
    }

    // MARK: - Requests

    func hello() async throws -> DaemonLink.Hello {
        DaemonLink.Hello(protocolVersion: FilaProtocol.version, backend: .local(reach: reach))
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
    /// an unregistered name are both `XPC_ERROR_CONNECTION_INVALID`, with the
    /// difference visible only in XPC's own log line — so ask the filesystem
    /// the question we actually mean: open the directory our container sits in,
    /// which the sandbox does not grant and which the app's own user owns. No
    /// hardcoded path, nothing private, and the answer is exactly the claim we
    /// are about to make to the user.
    static func probeReach(container: String = NSHomeDirectory()) -> DaemonLink.Reach {
        let directory = URL(fileURLWithPath: container, isDirectory: true).deletingLastPathComponent()
        guard let handle = opendir(directory.path) else { return .container }
        closedir(handle)
        return .user
    }

    func list(directory: String, cursor: UInt64) async throws -> DaemonLink.DirectoryPage {
        try await run {
            let page = try self.listings.page(directory: directory, cursor: cursor)
            return DaemonLink.DirectoryPage(entries: page.entries, cursor: page.cursor)
        }
    }

    func details(of path: String) async throws -> FileDetails {
        try await run { try self.operations.details(of: path) }
    }

    /// A descriptor the caller owns and must close, exactly as when the daemon
    /// opens one — the difference is only who opened it. The bytes were never
    /// going through a message either way.
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try await run { try self.operations.open(path, flags: flags, mode: mode) }
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try await run { try self.operations.create(template, at: path) }
    }

    func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws {
        try await run {
            try self.operations.rename(source, to: destination, exclusive: exclusive, overrideGuard: overrideGuard)
        }
    }

    func setAttributes(_ change: AttributeChange, at path: String) async throws {
        try await run { try self.operations.setAttributes(change, at: path) }
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await run { try self.operations.replaceItem(at: target, withTemporary: temporary) }
    }

    func mountPoints() async throws -> [MountPoint] {
        try await run { try self.operations.mountPoints() }
    }

    func volumeInfo(for path: String) async throws -> VolumeInfo {
        try await run { try self.operations.volumeInfo(for: path) }
    }

    func extendedAttribute(_ name: String, at path: String) async throws -> Data {
        try await run { try self.operations.extendedAttribute(name, at: path) }
    }

    func startJob(_ job: JobRequest) async throws -> UInt64 {
        try await run {
            let identifier = self.nextJobIdentifier
            self.nextJobIdentifier &+= 1

            let work: any RunningJob = job.kind.isArchive
                ? ArchiveJob(request: job, operations: self.operations)
                : FileJob(request: job, operations: self.operations)
            self.jobs[identifier] = work
            let lane = job.kind == .search ? self.searchQueue : self.jobQueue
            lane.async {
                let outcome = work.run { progress in
                    self.events.yield(DaemonLink.JobUpdate(identifier: identifier, event: .progress(progress)))
                } matches: { batch in
                    self.matches.yield(DaemonLink.SearchUpdate(identifier: identifier, batch: batch))
                } note: { line in
                    FilaLog.warning("job \(identifier): \(line)")
                }
                self.events.yield(DaemonLink.JobUpdate(identifier: identifier, event: .completed(outcome)))
                // Dropped after the completion is out, so a cancel that arrives
                // in between still finds the job rather than silently doing
                // nothing.
                self.queue.async { self.jobs[identifier] = nil }
            }
            return identifier
        }
    }

    func cancelJob(_ identifier: UInt64) async throws {
        try await run { self.jobs[identifier]?.cancel() }
    }

    /// There is no daemon, so there is no daemon log. The app's own lines are
    /// already in `FilaLog`, where the log screen reads them without asking
    /// anybody.
    func fetchLog(since _: UInt64, level _: FilaLog.Level) async throws
        -> (records: [FilaLog.Record], dropped: UInt64) {
        ([], 0)
    }

    // MARK: - Off the caller's thread

    /// Runs one blocking operation on `queue` and hands the result back.
    ///
    /// `withCheckedThrowingContinuation` rather than a `Task.detached`, because
    /// the point is the *serial* queue: the listing registry and the job table
    /// have exactly one owner, the same way they do in the daemon.
    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
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
