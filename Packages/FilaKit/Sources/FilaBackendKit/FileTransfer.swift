import Darwin
import Foundation

/// Whether the sources stay where they are afterwards.
public enum TransferMode: Sendable, Equatable {
    case copy
    case move
}

public extension Notification.Name {
    /// Posted by the app whenever its clipboard of locations changes: taken,
    /// pasted, cleared, or a paste started or ended.
    static let filaClipboardChanged = Notification.Name("wiki.qaq.fila.clipboard")
}

/// Where a transfer reads from: one backend, one service, the roots to
/// carry. Every root is a direct child of some directory on that backend;
/// the transfer carries it, and everything under it, by name.
public struct TransferSource: Sendable {
    public let backend: BackendID
    public let service: any FileService
    public let paths: [ServicePath]

    public init(backend: BackendID, service: any FileService, paths: [ServicePath]) {
        self.backend = backend
        self.service = service
        self.paths = paths
    }
}

/// Where a transfer writes to: the directory every root lands in, by its
/// own name.
public struct TransferDestination: Sendable {
    public let backend: BackendID
    public let service: any WritableFileService
    public let directory: ServicePath

    public init(backend: BackendID, service: any WritableFileService, directory: ServicePath) {
        self.backend = backend
        self.service = service
        self.directory = directory
    }
}

/// One transfer's whole ask.
public struct TransferRequest: Sendable {
    public let source: TransferSource
    public let destination: TransferDestination
    public let mode: TransferMode
    public let policy: PublishPolicy

    public init(source: TransferSource, destination: TransferDestination, mode: TransferMode, policy: PublishPolicy) {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.policy = policy
    }

    /// Both ends on one backend: a move is that backend's own rename, and
    /// a copy still relays, because the neutral contract has no
    /// server-side copy.
    public var isSameBackend: Bool { source.backend == destination.backend }
}

/// How far a transfer has got, as one operation: bytes over every leg the
/// transfer knew it would need — a relayed file counts its download and
/// its upload — so the bar does not reach the end while an upload is still
/// pending. Items are files and directories settled at the destination.
public struct TransferProgressReport: Sendable, Equatable {
    public var bytesDone: Int64
    /// Zero while the plan is still being made.
    public var bytesTotal: Int64
    public var itemsDone: Int64
    public var itemsTotal: Int64
    /// What is being carried right now.
    public var currentName: String
    /// True while the plan is still being built: the counts grow but the
    /// bar means nothing yet.
    public var planning: Bool

    public init(bytesDone: Int64, bytesTotal: Int64, itemsDone: Int64, itemsTotal: Int64, currentName: String, planning: Bool) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.currentName = currentName
        self.planning = planning
    }
}

/// Why a transfer did not start, or could not go on. Decided here, before
/// or between backend calls; a backend's own refusal is thrown as itself.
public enum TransferRefusal: Error, Sendable, Equatable {
    case nothingToTransfer
    /// Two roots share a name and would land on one destination.
    case conflictingNames(String)
    /// A root is already in the destination directory of its own backend.
    case sameLocation(ServicePath)
    /// The destination is a root, or under one, on the same backend.
    case insideSource(ServicePath)
    /// A move needs the source removed afterwards, and this source cannot
    /// remove anything.
    case sourceNotWritable
    /// The destination backend takes no writes at all. Decided by the
    /// caller before a request can be built, and reported like the rest.
    case destinationNotWritable
    /// The staging volume has less room than the next file needs.
    case insufficientStagingSpace(needed: Int64, available: Int64)
    /// The destination reported the published file at a different length
    /// than was written: the copy is not trusted and the source is kept.
    case sizeMismatch(ServicePath, expected: Int64, found: Int64)
}

/// What a transfer that ran to its end still owes the user an explanation
/// for. Thrown as the outcome's failure when it is not empty; a move with
/// anything retained has not moved, and a copy with anything skipped has
/// not copied everything.
public struct TransferShortfall: Error, Sendable, Equatable {
    /// Links and special files, which the neutral contract does not carry
    /// and this transfer refuses to dereference on the user's behalf.
    public var skipped: [ServicePath] = []
    /// Sources that were copied and published but not removed: they
    /// changed after being read, could not be re-read, refused removal, or
    /// are directories something was left in.
    public var retained: [ServicePath] = []
    /// Destinations whose publication reply never came.
    public var uncertain: [ServicePath] = []

    public init(skipped: [ServicePath] = [], retained: [ServicePath] = [], uncertain: [ServicePath] = []) {
        self.skipped = skipped
        self.retained = retained
        self.uncertain = uncertain
    }

    public var isEmpty: Bool { skipped.isEmpty && retained.isEmpty && uncertain.isEmpty }
}

/// How a transfer ended, whatever happened on the way.
public struct TransferOutcome: Sendable {
    /// Nil when everything asked for was done. `CancellationError` when the
    /// task was cancelled; `TransferShortfall` when it ran to the end with
    /// something left over; otherwise the refusal or backend error that
    /// stopped it, with everything published before it left in place.
    public let failure: Error?
    /// Directories on both backends whose listings are stale now — after a
    /// failure as much as after a success, since a partial transfer changed
    /// them too.
    public let affected: [FileLocation]
    /// Files published at the destination, complete and verified.
    public let publishedFiles: Int

    public init(failure: Error?, affected: [FileLocation], publishedFiles: Int) {
        self.failure = failure
        self.affected = affected
        self.publishedFiles = publishedFiles
    }

    public var succeeded: Bool { failure == nil }
    public var wasCancelled: Bool { failure is CancellationError }
}

/// A copy or move between two file backends, or within one.
///
/// **Publish first, then clean up.** Every root is carried in full — its
/// directories created, its files written to a private temporary beside
/// their destination and published in one step, each publication checked
/// against the length that was written — before anything at the source is
/// touched. A move then revalidates each copied file against what was read
/// (its size and modification time) and removes only the ones that still
/// match, one file at a time, and then each directory only while it is
/// empty. Nothing re-lists the source tree to delete it: a file that
/// appeared after the copy stays, and so does every directory above it,
/// reported as retained.
///
/// **One file in memory at a time, never a tree.** A source that hands out
/// descriptors is read straight into the destination's write. Any other
/// source is staged: one file into the staging directory, uploaded, removed,
/// then the next. The plan itself — one entry per file and directory — is
/// the only thing held for the whole tree.
///
/// **What is not carried is said.** Links and special files are skipped and
/// listed in the outcome rather than dereferenced or dropped in silence.
/// Ownership, modes, extended attributes and flags are not carried across
/// backends: the destination gives every file its own defaults.
///
/// **A lost reply is not a failure.** A publication whose reply never came
/// stops the transfer with the path marked uncertain; the caller lists the
/// destination again and the source is kept.
///
/// Cancellation is honoured between files and inside every read and write;
/// what was published stays, the staging file and the destination's
/// temporary go, and the outcome says cancelled.
public enum FileTransfer {
    /// Runs `request`, staging through `staging` — a directory the caller
    /// owns, empties and removes afterwards — and reporting through
    /// `progress` from whatever thread the backends report on.
    public static func run(
        _ request: TransferRequest,
        staging: URL,
        progress: @escaping @Sendable (TransferProgressReport) -> Void
    ) async -> TransferOutcome {
        await Run(request: request, staging: staging, progress: progress).execute()
    }
}

// MARK: - Plan

/// One thing to carry, in the order it is carried: a directory before
/// anything inside it.
private enum Step {
    case directory(source: ServicePath, target: ServicePath)
    case file(source: ServicePath, target: ServicePath, size: Int64, modified: Date?)

    var source: ServicePath {
        switch self {
        case let .directory(source, _): source
        case let .file(source, _, _, _): source
        }
    }
}

// MARK: - Meter

/// The one owner of a transfer's counts and its report closure. Backends
/// report progress from their own threads — an SMB actor, a local dispatch
/// queue — so every read and write of the tally goes through this lock, and
/// so does emitting the report, which is why the closure never sees a
/// half-updated number.
private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (TransferProgressReport) -> Void

    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var itemsDone: Int64 = 0
    private var itemsTotal: Int64 = 0
    private var currentName = ""
    private var planning = true

    init(report: @escaping @Sendable (TransferProgressReport) -> Void) {
        self.report = report
    }

    func addPlanned(items: Int64, bytes: Int64) {
        lock.lock()
        itemsTotal += items
        bytesTotal += bytes
        lock.unlock()
    }

    /// Planning is over; carrying begins. The bar is meaningful from here.
    func startCarrying() {
        lock.lock()
        planning = false
        lock.unlock()
        emit()
    }

    func itemFinished(name: String) {
        lock.lock()
        itemsDone += 1
        currentName = name
        lock.unlock()
        emit()
    }

    func beginItem(name: String) {
        lock.lock()
        currentName = name
        lock.unlock()
        emit()
    }

    /// Adds `delta` transferred bytes. Called from a backend's own thread.
    func addBytes(_ delta: Int64) {
        guard delta > 0 else { return }
        lock.lock()
        bytesDone += delta
        lock.unlock()
        emit()
    }

    func snapshotWhilePlanning(name: String) {
        lock.lock()
        currentName = name
        lock.unlock()
        emit()
    }

    private func emit() {
        lock.lock()
        let report = TransferProgressReport(
            bytesDone: bytesDone, bytesTotal: bytesTotal,
            itemsDone: itemsDone, itemsTotal: itemsTotal,
            currentName: currentName, planning: planning
        )
        lock.unlock()
        self.report(report)
    }

    /// A per-leg counter that turns a backend's absolute `completed` into
    /// deltas this meter can accumulate: each `copyContents` and `writeFile`
    /// leg gets its own so the two legs of one relayed file both count.
    func legCounter() -> @Sendable (TransferProgress) -> Void {
        let last = Atomic()
        return { [weak self] progress in
            let delta = progress.completed - last.swap(progress.completed)
            self?.addBytes(delta)
        }
    }

    private final class Atomic: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func swap(_ new: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            let old = value
            value = new
            return old
        }
    }
}

// MARK: - Run

private final class Run {
    private let request: TransferRequest
    private let staging: URL
    private let meter: Meter

    private var steps: [Step] = []
    private var shortfall = TransferShortfall()
    /// Files copied and verified at the destination, in carry order.
    private var copied: [Step] = []
    /// Source directories, deepest last as planned; cleaned bottom-up.
    private var sourceDirectories: [ServicePath] = []
    private var publishedFiles = 0
    /// Source directories a move emptied, for the invalidation list.
    private var touchedSourceDirectories: Set<ServicePath> = []

    /// Bytes per `read(2)` of a staged file back out for the upload leg.
    private static let chunkSize = 1 << 20

    init(request: TransferRequest, staging: URL, progress: @escaping @Sendable (TransferProgressReport) -> Void) {
        self.request = request
        self.staging = staging
        meter = Meter(report: progress)
    }

    func execute() async -> TransferOutcome {
        do {
            try refuseEarly()
            if request.isSameBackend, request.mode == .move {
                try await renameInPlace()
            } else {
                try await plan()
                meter.startCarrying()
                try await carry()
                if request.mode == .move {
                    try await cleanUpSource()
                }
            }
            return outcome(shortfall.isEmpty ? nil : shortfall)
        } catch {
            return outcome(error)
        }
    }

    // MARK: Refusals

    private func refuseEarly() throws {
        let source = request.source
        guard !source.paths.isEmpty else { throw TransferRefusal.nothingToTransfer }
        var names: Set<String> = []
        for path in source.paths {
            // A root has no name to land under; there is nothing to carry.
            guard let name = path.name else { throw TransferRefusal.nothingToTransfer }
            guard names.insert(name).inserted else { throw TransferRefusal.conflictingNames(name) }
            guard request.isSameBackend else { continue }
            let destination = request.destination.directory
            if path.parent == destination {
                throw TransferRefusal.sameLocation(path)
            }
            // A destination at or under a source root would copy a folder
            // into itself; refuse it before the first byte.
            if destination == path || destination.components.starts(with: path.components) {
                throw TransferRefusal.insideSource(path)
            }
        }
        if request.mode == .move, !(source.service is any WritableFileService) {
            throw TransferRefusal.sourceNotWritable
        }
    }

    // MARK: Same-backend move

    /// The backend's own rename, root by root. A refusal on one root leaves
    /// the earlier ones moved and stops; nothing is rolled back.
    private func renameInPlace() async throws {
        let destination = request.destination
        meter.addPlanned(items: Int64(request.source.paths.count), bytes: 0)
        meter.startCarrying()
        for path in request.source.paths {
            try Task.checkCancellation()
            let name = path.name ?? ""
            meter.beginItem(name: name)
            try await destination.service.move(path, to: destination.directory.appending(name), policy: request.policy)
            if let parent = path.parent { touchedSourceDirectories.insert(parent) }
            publishedFiles += 1
            meter.itemFinished(name: name)
        }
    }

    // MARK: Planning

    /// The direct legs one file costs: 1 when the source hands out a
    /// descriptor (read straight into the write), 2 when it must be staged
    /// (download then upload).
    private var legsPerFile: Int64 { request.source.service is any DescriptorFileService ? 1 : 2 }

    /// Every root described, every directory under one listed once. Links
    /// and special files are recorded as skipped and never entered.
    private func plan() async throws {
        let source = request.source.service
        for root in request.source.paths {
            try Task.checkCancellation()
            let name = root.name ?? ""
            let target = try request.destination.directory.appending(name)
            let entry = try await source.details(root)
            switch entry.kind {
            case .file:
                append(.file(source: root, target: target, size: entry.size ?? 0, modified: entry.modified))
            case .directory:
                append(.directory(source: root, target: target))
                try await walk(root, into: target)
            case .symbolicLink, .other:
                shortfall.skipped.append(root)
            }
        }
        guard !steps.isEmpty else {
            // Every root was something the transfer does not carry: say so
            // rather than reporting an empty success.
            throw shortfall
        }
    }

    private func walk(_ directory: ServicePath, into target: ServicePath) async throws {
        // Depth first through an explicit stack, so the recursion depth is
        // the tree's and the listing cursors are opened one at a time.
        var pending: [(ServicePath, ServicePath)] = [(directory, target)]
        while let (sourceDirectory, targetDirectory) = pending.popLast() {
            var subdirectories: [(ServicePath, ServicePath)] = []
            for try await batch in try await request.source.service.list(sourceDirectory) {
                try Task.checkCancellation()
                for entry in batch {
                    let child = try sourceDirectory.appending(entry.name)
                    let childTarget = try targetDirectory.appending(entry.name)
                    switch entry.kind {
                    case .file:
                        append(.file(source: child, target: childTarget, size: entry.size ?? 0, modified: entry.modified))
                    case .directory:
                        append(.directory(source: child, target: childTarget))
                        subdirectories.append((child, childTarget))
                    case .symbolicLink, .other:
                        shortfall.skipped.append(child)
                    }
                }
            }
            // Reversed so the stack pops them in listing order.
            pending.append(contentsOf: subdirectories.reversed())
        }
    }

    private func append(_ step: Step) {
        steps.append(step)
        if case let .directory(source, _) = step {
            sourceDirectories.append(source)
            meter.addPlanned(items: 1, bytes: 0)
        }
        if case let .file(_, _, size, _) = step {
            meter.addPlanned(items: 1, bytes: size * legsPerFile)
            // Planning progress: the counts grow, the bar stays
            // indeterminate until carrying begins.
            meter.snapshotWhilePlanning(name: step.source.name ?? "")
        }
    }

    // MARK: Carrying

    private func carry() async throws {
        let destination = request.destination.service
        for step in steps {
            try Task.checkCancellation()
            let name = step.source.name ?? ""
            meter.beginItem(name: name)
            switch step {
            case let .directory(_, target):
                do {
                    try await destination.createDirectory(target)
                } catch let WriteFailure.alreadyExists(path) where request.policy == .replace {
                    // Replacing a directory means filling it: what is there
                    // is kept, files inside are replaced one by one. A file
                    // where the directory should be is not something to fill,
                    // and neither is a link to a directory: filling it would
                    // write wherever the link points, which the user never
                    // named. The source side skips links; so does this side.
                    let existing = try await destination.details(path)
                    guard existing.kind == .directory else { throw WriteFailure.alreadyExists(path) }
                }
            case let .file(source, target, size, _):
                let published: Int64
                do {
                    published = try await carryFile(source, to: target, size: size)
                } catch let WriteFailure.publicationUnknown(path) {
                    // The reply never came. The file may be at its name or
                    // not; the transfer stops here, says which name it cannot
                    // vouch for, and a move keeps every source it copied.
                    shortfall.uncertain.append(path)
                    throw shortfall
                }
                publishedFiles += 1
                if published == size {
                    copied.append(step)
                } else if request.mode == .move {
                    // The destination holds what was read, whole — but the
                    // source is not the file the plan described, so it is
                    // not one this move can vouch for removing.
                    shortfall.retained.append(source)
                }
            }
            meter.itemFinished(name: name)
        }
    }

    /// Carries one file and returns the length the destination reports for
    /// it. Equal to `size` unless the source grew or shrank between the
    /// plan and the read; then it is the source's current length, and the
    /// copy is whole for that. Anything else is a mismatch.
    private func carryFile(_ source: ServicePath, to target: ServicePath, size: Int64) async throws -> Int64 {
        let descriptor: Int32
        var stagingFile: URL?
        if let direct = request.source.service as? any DescriptorFileService {
            descriptor = try await direct.openForReading(source)
        } else {
            let file = staging.appendingPathComponent(UUID().uuidString)
            try checkStagingSpace(for: size)
            descriptor = try Self.openStaging(file)
            stagingFile = file
            do {
                try await request.source.service.copyContents(of: source, to: descriptor, progress: meter.legCounter())
                guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw StagingFailure(code: errno, path: file.path) }
            } catch {
                close(descriptor)
                unlink(file.path)
                throw error
            }
        }
        defer {
            close(descriptor)
            if let stagingFile { unlink(stagingFile.path) }
        }
        try await request.destination.service.writeFile(
            from: descriptor,
            size: size,
            to: target,
            policy: request.policy,
            progress: meter.legCounter()
        )
        // Length is the evidence a move deletes the source on. The write
        // pumps to end of file, so a source that changed size before it was
        // read publishes at its new length — complete, and confirmed by
        // asking the source again. A length neither the plan nor the source
        // explains is a server that wrote something else: not trusted, and
        // the source is kept.
        let published = try await request.destination.service.details(target)
        guard let found = published.size, found != size else { return size }
        let current = try? await request.source.service.details(source)
        guard current?.kind == .file, current?.size == found else {
            throw TransferRefusal.sizeMismatch(target, expected: size, found: found)
        }
        return found
    }

    private func checkStagingSpace(for size: Int64) throws {
        guard size > 0 else { return }
        var stats = statfs()
        guard statfs(staging.path, &stats) == 0 else { return }
        let available = Int64(stats.f_bavail) * Int64(stats.f_bsize)
        guard available >= size else {
            throw TransferRefusal.insufficientStagingSpace(needed: size, available: available)
        }
    }

    private static func openStaging(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StagingFailure(code: errno, path: url.path) }
        return descriptor
    }

    // MARK: Source cleanup

    /// A move's second half: remove exactly what was copied and verified,
    /// nothing a fresh listing turns up. Files first, revalidated against
    /// what was read; then directories bottom-up, each only while empty.
    /// Anything that changed, refused, or is not empty is retained and
    /// reported, and the move is a partial move rather than a success.
    ///
    /// Cancellation throws, between one node and the next, so a move
    /// stopped half-way through its cleanup is reported cancelled — never
    /// as a success with the sources it had not reached still in place.
    private func cleanUpSource() async throws {
        guard let writable = request.source.service as? any WritableFileService else {
            // refuseEarly already rejected a move a non-writable source
            // could not clean up; this cannot happen.
            shortfall.retained.append(contentsOf: copied.map(\.source))
            return
        }
        for step in copied {
            try Task.checkCancellation()
            guard case let .file(source, _, size, modified) = step else { continue }
            do {
                let current = try await request.source.service.details(source)
                // Changed since it was read: another writer touched it, so
                // this move is not the last word on it. Keep it.
                guard current.kind == .file, current.size == size, current.modified == modified else {
                    shortfall.retained.append(source)
                    continue
                }
                try await writable.removeFile(source)
                if let parent = source.parent { touchedSourceDirectories.insert(parent) }
            } catch {
                shortfall.retained.append(source)
            }
        }
        // Deepest first: a child directory is emptied before its parent is
        // tried. A directory that still has entries — a retained file, or
        // something added after the copy — refuses and is kept, and so is
        // every directory above it, because they are not empty either.
        var blocked: Set<ServicePath> = []
        for directory in sourceDirectories.reversed() {
            try Task.checkCancellation()
            let parent = directory.parent
            guard !blocked.contains(directory) else {
                shortfall.retained.append(directory)
                if let parent { blocked.insert(parent) }
                continue
            }
            do {
                try await writable.removeEmptyDirectory(directory)
                if let parent { touchedSourceDirectories.insert(parent) }
            } catch {
                shortfall.retained.append(directory)
                if let parent { blocked.insert(parent) }
            }
        }
    }

    // MARK: Outcome

    private func outcome(_ failure: Error?) -> TransferOutcome {
        // A lost publication reply is not a failure the caller retries. It
        // surfaces as an uncertain path inside the shortfall, kept even
        // when nothing else went wrong.
        // Source directories on the source backend, the destination on its
        // own: a hint delivered to the wrong backend is a listing of a path
        // that may not exist there.
        var directories: Set<ServicePath> = []
        for path in request.source.paths {
            if let parent = path.parent { directories.insert(parent) }
        }
        for directory in touchedSourceDirectories { directories.insert(directory) }
        let sourceLocations = directories.map { FileLocation(backend: request.source.backend, path: $0) }
        let destinationLocation = FileLocation(backend: request.destination.backend, path: request.destination.directory)
        var affected = [destinationLocation]
        affected.append(contentsOf: sourceLocations.filter { $0 != destinationLocation })
        return TransferOutcome(failure: failure, affected: affected, publishedFiles: publishedFiles)
    }
}

/// A staging descriptor refused to open or seek. Its errno, and the path
/// under the staging directory it happened on.
public struct StagingFailure: Error, Sendable, Equatable, LocalizedError {
    public let code: Int32
    public let path: String
    public init(code: Int32, path: String) {
        self.code = code
        self.path = path
    }
    public var errorDescription: String? {
        String(localized: "The file could not be saved on this device. Try again.")
    }
}
