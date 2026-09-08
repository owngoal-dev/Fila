import Darwin
import Dispatch
import FilaFileOps
import FilaProtocol
import Foundation

/// A `.compress` or an `.extract`, run to completion on the calling thread.
///
/// The one job that moves file bytes itself, which is why it never runs inside
/// `filad`: on a device it is the body of `fila-archive`, a process the daemon
/// spawns and signals, and in the app without a daemon it runs in-process. The
/// filesystem it touches goes through `FileOperations` either way, so the guard
/// and the atomic replace are the same ones every other write uses.
///
/// Every path an archive supplies is joined to the destination in exactly one
/// place, `Placement`, and nothing is created through a link this run planted.
public final class ArchiveJob: @unchecked Sendable {
    private let request: JobRequest
    private let options: ArchiveOptions
    private let operations: FileOperations
    private let cancellation = NSLock()
    private var cancelled = false

    public init(request: JobRequest, operations: FileOperations) {
        self.request = request
        options = request.archive ?? ArchiveOptions()
        self.operations = operations
    }

    /// Asks the job to stop at its next chunk. Safe from any thread.
    public func cancel() {
        cancellation.lock()
        cancelled = true
        cancellation.unlock()
    }

    public var isCancelled: Bool {
        cancellation.lock()
        defer { cancellation.unlock() }
        return cancelled
    }

    /// `note` carries what the outcome cannot: a member skipped for a reason
    /// the user should be able to find in the log.
    public func run(report: @escaping (JobProgress) -> Void, note: @escaping (String) -> Void = { _ in }) -> FilaFailure {
        let progress = Progress(report: report)
        do {
            switch request.kind {
            case .compress: try compress(progress)
            case .extract: try extract(progress, note: note)
            default: throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
            }
            progress.flush()
            return FilaFailure(code: .success)
        } catch let failure as FilaFailure {
            return failure
        } catch let failure as FormatFailure {
            note("libarchive: \(failure)")
            return Self.outcome(for: failure, path: progress.currentPath)
        } catch {
            return FilaFailure(code: .operationFailed)
        }
    }

    private static func outcome(for failure: FormatFailure, path: String) -> FilaFailure {
        switch failure {
        case .cancelled: return FilaFailure(code: .cancelled, path: path)
        case .wrongPassword: return FilaFailure(code: .wrongPassword, path: path)
        case let .system(code): return FilaFailure(errno: code, path: path)
        case .tooLarge: return FilaFailure(code: .operationFailed, systemError: EFBIG, path: path)
        case .damaged, .unsupported, .notRecognised: return FilaFailure(code: .operationFailed, systemError: EFTYPE, path: path)
        }
    }

    private func checkCancelled(_ path: String) throws {
        if isCancelled { throw FilaFailure(code: .cancelled, path: path) }
    }

    // MARK: - Compress

    private func compress(_ progress: Progress) throws {
        guard let destination = request.destination else { throw FilaFailure(code: .invalidRequest) }
        let target = try FilaPath.canonical(destination)
        guard !filaExists(target) else { throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: target) }

        let members = try collect()
        progress.total(bytes: members.reduce(0) { $0 + $1.byteCount }, items: Int64(members.count))

        // Written under a temporary name and renamed into place: a zip whose
        // central directory never got written is not a partial archive, it is
        // an unopenable one, and it must not appear under the real name.
        let temporary = FilaPath.join(FilaPath.directory(of: target), ".fila-archive-\(UUID().uuidString)")
        let descriptor = try operations.open(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        defer { close(descriptor) }
        do {
            try write(members, to: descriptor, progress: progress)
            try operations.setAttributes(.newItemDefaults, at: temporary)
            try synchronize(descriptor, path: temporary)
            try checkCancelled(target)
            try operations.rename(temporary, to: target, exclusive: true)
        } catch {
            unlink(temporary)
            throw error
        }
    }

    private struct Member {
        var name: String
        var path: String
        var kind: FileKind
        var mode: mode_t
        var modified: Date
        var byteCount: Int64
        var linkTarget: String?
    }

    /// The selection expanded into the entries the archive will hold, named
    /// relative to the directory the sources came from. Only a real directory
    /// is descended into: a symlink to one is stored as the link it is, which
    /// is also what stops a link back into `/private` from archiving the
    /// volume twice.
    private func collect() throws -> [Member] {
        var members: [Member] = []
        for source in request.sources {
            let path = try FilaPath.canonical(source)
            try append(path, as: FilaPath.name(of: path), into: &members)
        }
        return members
    }

    private func append(_ path: String, as name: String, into members: inout [Member]) throws {
        try checkCancelled(path)
        var metadata = stat()
        try filaCheck(path) { lstat(path, &metadata) }
        let kind = FileKind(modeBits: metadata.st_mode)
        var linkTarget: String?
        if kind == .symbolicLink {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { throw FilaFailure(errno: Darwin.errno, path: path) }
            linkTarget = String(cString: buffer)
        }
        guard members.count < ArchiveReader.maximumEntryCount else { throw FilaFailure(errno: E2BIG, path: path) }
        members.append(Member(
            name: name,
            path: path,
            kind: kind,
            mode: metadata.st_mode & 0o7777,
            modified: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
            byteCount: kind == .regular ? Int64(metadata.st_size) : 0,
            linkTarget: linkTarget
        ))
        guard kind == .directory else { return }
        guard let handle = opendir(path) else { throw FilaFailure(errno: Darwin.errno, path: path) }
        var names: [String] = []
        Darwin.errno = 0
        while let entry = readdir(handle) {
            let child = filaText(entry.pointee.d_name)
            if child != ".", child != ".." { names.append(child) }
        }
        let failed = Darwin.errno
        closedir(handle)
        guard failed == 0 else { throw FilaFailure(errno: failed, path: path) }
        for child in names.sorted() {
            try append(FilaPath.join(path, child), as: name + "/" + child, into: &members)
        }
    }

    private func write(_ members: [Member], to descriptor: Int32, progress: Progress) throws {
        let writer = try ArchiveWriter(
            descriptor: descriptor,
            format: options.format,
            zipCompression: options.zipCompression,
            encryption: options.encryption,
            password: options.password
        )
        for member in members {
            try checkCancelled(member.path)
            progress.beginItem(member.path)
            switch member.kind {
            case .directory:
                try writer.addDirectory(member.name, mode: member.mode, modified: member.modified)
            case .symbolicLink:
                // A link with no readable target would go in with an empty
                // one, which is a member the extractor refuses.
                guard let target = member.linkTarget, !target.isEmpty else {
                    throw FilaFailure(code: .operationFailed, systemError: EINVAL, path: member.path)
                }
                try writer.addSymbolicLink(member.name, target: target, mode: member.mode, modified: member.modified)
            case .regular:
                let source = try operations.open(member.path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW, mode: 0)
                defer { close(source) }
                try writer.addFile(member.name, from: source, mode: member.mode, modified: member.modified) { done, _ in
                    progress.fileProgress(done)
                    return !self.isCancelled
                }
            case .fifo, .socket, .blockDevice, .characterDevice, .unknown:
                throw FilaFailure(code: .operationFailed, systemError: EFTYPE, path: member.path)
            }
            progress.finishedItem(bytes: member.byteCount)
        }
        try writer.finish()
    }

    // MARK: - Extract

    /// One forward pass over the archive, creating only what was selected.
    ///
    /// Symbolic links are held back and created after everything else: an
    /// entry symlink's target is as attacker-controlled as its name, and a
    /// link created early is a link a later entry can be written *through*.
    /// Ordering alone is not enough (two link entries can nest), so
    /// `Placement` also refuses any path that passes through a link this run
    /// planted.
    private func extract(_ progress: Progress, note: (String) -> Void) throws {
        guard let source = request.sources.first, let destination = request.destination else {
            throw FilaFailure(code: .invalidRequest)
        }
        let archive = try FilaPath.canonical(source)
        let descriptor = try operations.open(archive, flags: O_RDONLY | O_NONBLOCK, mode: 0)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw FilaFailure(errno: errno, path: archive) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: EINVAL, path: archive) }
        let reader = try ArchiveReader(descriptor: descriptor, name: FilaPath.name(of: archive), password: options.password)
        let placement = Placement(operations: operations, destination: try FilaPath.canonical(destination), overwrite: request.overwrite)
        try placement.prepare()

        // Matched by position, never by name — see `ArchiveSelection`.
        var wanted = options.members.map { selection in
            Dictionary(selection.map { ($0.index, $0.declaredPath) }, uniquingKeysWith: { first, _ in first })
        }
        progress.total(bytes: 0, items: Int64(wanted?.count ?? 0))

        var links: [ArchiveEntry] = []
        var index: Int64 = -1
        var remainingMetadata = ArchiveReader.maximumListingByteCount
        while wanted?.isEmpty != true, let entry = try reader.next() {
            index += 1
            guard index < ArchiveReader.maximumEntryCount else { throw FilaFailure(errno: E2BIG, path: archive) }
            let retainedBytes = entry.declaredPath.utf8.count + (entry.linkTarget?.utf8.count ?? 0) + (entry.hardLinkTarget?.utf8.count ?? 0)
            guard retainedBytes <= remainingMetadata else { throw FilaFailure(errno: E2BIG, path: archive) }
            remainingMetadata -= retainedBytes
            try checkCancelled(entry.declaredPath)
            if wanted != nil {
                guard let listed = wanted?.removeValue(forKey: index) else { continue }
                // The listing and this pass are two reads of a file on a
                // filesystem the user is also using. A member that is no
                // longer the one they ticked is not theirs to receive.
                guard listed == entry.declaredPath else {
                    note("skipped “\(entry.declaredPath)”: the archive changed after it was listed")
                    progress.finishedItem(bytes: 0)
                    continue
                }
            }
            progress.beginItem(entry.declaredPath)
            // Their headers carry everything needed, so nothing is re-read.
            if entry.isSymbolicLink {
                links.append(entry)
                continue
            }
            try place(entry, with: placement, from: reader, progress: progress, note: note)
        }
        for entry in links {
            try checkCancelled(entry.declaredPath)
            progress.beginItem(entry.declaredPath)
            try place(entry, with: placement, from: reader, progress: progress, note: note)
        }
        try placement.finish()
    }

    private func place(
        _ entry: ArchiveEntry,
        with placement: Placement,
        from reader: ArchiveReader,
        progress: Progress,
        note: (String) -> Void
    ) throws {
        do {
            try placement.place(entry, from: reader) { done, _ in
                progress.fileProgress(done)
                return !self.isCancelled
            }
        } catch let skipped as Placement.Skipped {
            // A member the archive cannot be trusted with is left out and said
            // so; a member the filesystem refused stops the job with its errno.
            note("skipped “\(entry.declaredPath)”: \(skipped.reason)")
        }
        progress.finishedItem(bytes: entry.byteCount ?? 0)
    }

    // MARK: - Progress

    /// Throttled the way `JobTally` is: a large member reports thousands of
    /// times a second, and a bar cannot show more than a few.
    private final class Progress {
        private let report: (JobProgress) -> Void
        private var bytesTotal: Int64 = 0
        private var itemsTotal: Int64 = 0
        private var completedBytes: Int64 = 0
        private var currentFileBytes: Int64 = 0
        private var itemsDone: Int64 = 0
        private(set) var currentPath = ""
        private var lastReport = DispatchTime(uptimeNanoseconds: 1)

        init(report: @escaping (JobProgress) -> Void) {
            self.report = report
        }

        func total(bytes: Int64, items: Int64) {
            bytesTotal = bytes
            itemsTotal = items
        }

        func beginItem(_ path: String) {
            currentPath = path
            currentFileBytes = 0
            emit(throttled: true)
        }

        func fileProgress(_ bytes: Int64) {
            currentFileBytes = bytes
            emit(throttled: true)
        }

        func finishedItem(bytes: Int64) {
            completedBytes += bytes
            currentFileBytes = 0
            itemsDone += 1
            emit(throttled: true)
        }

        func flush() {
            emit(throttled: false)
        }

        private func emit(throttled: Bool) {
            let now = DispatchTime.now()
            if throttled, now.uptimeNanoseconds &- lastReport.uptimeNanoseconds < 100_000_000 { return }
            lastReport = now
            report(JobProgress(
                bytesDone: min(bytesTotal > 0 ? bytesTotal : .max, completedBytes + currentFileBytes),
                bytesTotal: bytesTotal,
                itemsDone: itemsDone,
                itemsTotal: itemsTotal,
                currentPath: currentPath
            ))
        }
    }
}

/// One extraction run, and the only place an archive-supplied name is joined
/// to the directory the user chose.
///
/// A type rather than functions because the safety of a name depends on what
/// earlier entries in the same run already created: a symlink an archive
/// planted two entries ago is the thing a later entry gets written *through*,
/// and only something that remembers the run can see it.
private final class Placement {
    /// A member left out on purpose. The reason goes to the log; the job
    /// carries on, because the rest of the archive is still the user's.
    struct Skipped: Error {
        var reason: String
    }

    private let operations: FileOperations
    private let destination: String
    private let overwrite: Bool

    /// Directories this run created. Only these get an archive's mode:
    /// extracting something with a `Library/` entry into `/var/mobile` must
    /// not chmod the user's own `Library` to whatever the archive felt like,
    /// as root.
    private var created: Set<String> = []
    private var directoryPermissions: [String: mode_t] = [:]
    /// Directories confirmed to be directories rather than symlinks pointing
    /// somewhere else. `mkdir(2)` answers `EEXIST` for both, and the
    /// difference is the whole attack.
    private var verified: Set<String> = []
    /// Relative paths this run created as symbolic links. Nothing may be
    /// written through one, including a later link entry.
    private var planted: Set<String> = []

    init(operations: FileOperations, destination: String, overwrite: Bool) {
        self.operations = operations
        self.destination = destination
        self.overwrite = overwrite
    }

    /// The destination itself, once and not per entry: a missing parent above
    /// it is one honest failure rather than one per member.
    func prepare() throws {
        if try makeDirectory(destination) { created.insert(destination) }
        verified.insert(destination)
    }

    func place(_ entry: ArchiveEntry, from reader: ArchiveReader, progress: @escaping ProgressHandler) throws {
        guard let relative = entry.relativePath else { throw Skipped(reason: "it points outside the destination") }
        guard entry.hardLinkTarget == nil else { throw Skipped(reason: "it is a hard link") }
        try refuseAPathThroughAPlantedLink(relative)
        let target = FilaPath.join(destination, relative)

        switch entry.kind {
        case .directory:
            try makeDirectories(relative)
            if created.contains(target) {
                directoryPermissions[target] = entry.permissions
            }

        case .symbolicLink:
            guard let linkTarget = entry.linkTarget, !linkTarget.isEmpty else {
                throw Skipped(reason: "it is a symbolic link with no target")
            }
            try makeDirectories(parent(of: relative))
            guard overwrite || !filaExists(target) else { throw Skipped(reason: "an item with that name already exists") }
            try operations.create(.symbolicLink(target: linkTarget), at: target, mode: entry.permissions)
            planted.insert(relative)

        case .regular:
            try makeDirectories(parent(of: relative))
            guard overwrite || !filaExists(target) else { throw Skipped(reason: "an item with that name already exists") }
            try write(from: reader, to: target, permissions: entry.permissions, progress: progress)

        // A fifo, a socket or a device node is a thing a tar can carry and a
        // file manager has no business creating.
        case .fifo, .socket, .blockDevice, .characterDevice, .unknown:
            throw Skipped(reason: "it is not a file or a folder")
        }
    }

    /// Read-only directory modes are applied after their children, deepest
    /// first. Existing destination directories keep their own permissions.
    func finish() throws {
        for path in directoryPermissions.keys.sorted(by: { $0.count > $1.count }) {
            try operations.setAttributes(AttributeChange(mode: directoryPermissions[path]!), at: path)
        }
    }

    private func parent(of relative: String) -> String {
        relative.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func refuseAPathThroughAPlantedLink(_ relative: String) throws {
        guard !planted.isEmpty else { return }
        var ancestor = ""
        for component in relative.split(separator: "/").dropLast() {
            ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
            guard !planted.contains(ancestor) else {
                throw Skipped(reason: "it would be written through a symbolic link in the archive")
            }
        }
    }

    /// Streams one member into a temporary beside the target and renames it
    /// in, so a member that fails halfway never replaces what was there.
    private func write(from reader: ArchiveReader, to target: String, permissions: mode_t, progress: @escaping ProgressHandler) throws {
        let temporary = FilaPath.join(FilaPath.directory(of: target), ".fila-tmp-\(UUID().uuidString)")
        let descriptor = try operations.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY, mode: 0o600)
        do {
            defer { close(descriptor) }
            try reader.read(into: descriptor, progress: progress)
            try filaCheck(temporary) { fchmod(descriptor, permissions) }
            try synchronize(descriptor, path: temporary)
        } catch {
            unlink(temporary)
            throw error
        }
        do {
            if overwrite {
                try operations.replaceItem(at: target, withTemporary: temporary, permissions: permissions)
            } else {
                try operations.rename(temporary, to: target, exclusive: true)
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// Every missing component of `relative` under the destination. An
    /// archive is under no obligation to list its directories at all, let
    /// alone before the files inside them.
    private func makeDirectories(_ relative: String) throws {
        var path = destination
        for component in relative.split(separator: "/") {
            path = FilaPath.join(path, String(component))
            guard !verified.contains(path) else { continue }
            if try makeDirectory(path) {
                created.insert(path)
            } else {
                try refuseANonDirectory(at: path)
            }
            verified.insert(path)
        }
    }

    /// EEXIST is the common case — most entries share a parent — and is not
    /// a failure; anything else is.
    private func makeDirectory(_ path: String) throws -> Bool {
        do {
            try operations.create(.directory, at: path, mode: 0o755)
            return true
        } catch let failure as FilaFailure where failure.systemError == EEXIST {
            return false
        }
    }

    /// What `EEXIST` does not say: whether the thing already there is a
    /// directory or a symlink pointing out of the destination entirely.
    private func refuseANonDirectory(at path: String) throws {
        guard try operations.details(of: path).node.kind != .directory else { return }
        throw Skipped(reason: "“\(path)” already exists and is not a folder")
    }
}

/// Flush file contents before the name becomes visible. A delayed write error
/// must leave the existing destination intact and remove only the temporary.
private func synchronize(_ descriptor: Int32, path: String) throws {
    while fsync(descriptor) != 0 {
        if errno != EINTR { throw FilaFailure(errno: errno, path: path) }
    }
}
