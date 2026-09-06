import CRemoveFile
import Darwin
import FilaProtocol
import Foundation

/// A copy, a move, a delete or a search — the first three running on
/// `copyfile(3)`, `removefile(3)`, `renameat(2)` and `clonefile(2)`.
///
/// Nothing that *changes* the filesystem is a hand-written tree walk, and that
/// is not laziness: libSystem preserves extended attributes, ACLs, resource
/// forks, BSD flags and sparseness, its memory is flat regardless of how big the
/// tree is, and its state callbacks are where progress and cancellation come
/// from. Every walk written by hand loses some of that silently, and the loss
/// shows up as the user's data quietly changing.
///
/// A search is the one walk written by hand, because there is no libSystem call
/// that streams name matches and nothing about a search can lose data. It earns
/// its place in the daemon by being flat in memory the same way the others are
/// — see `TreeSearch`.
public final class FileJob: @unchecked Sendable {
    private let request: JobRequest
    private let operations: FileOperations
    private let cancellation = NSLock()
    private var cancelled = false
    /// The archive helper running this job, while one is. Guarded by
    /// `cancellation`, and cleared before the pid is reaped so a late kill
    /// cannot land on whatever process inherits the number.
    private var helper: pid_t = 0

    public init(request: JobRequest, operations: FileOperations) {
        self.request = request
        self.operations = operations
    }

    /// Asks the job to stop at its next callback. Safe from any thread; the job
    /// itself runs on one. A helper is hung up and, if it ignores that, killed.
    public func cancel() {
        cancellation.lock()
        cancelled = true
        let pid = helper
        cancellation.unlock()
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.killHelper(pid)
        }
    }

    func attachHelper(_ pid: pid_t) {
        cancellation.lock()
        helper = pid
        let stop = cancelled
        cancellation.unlock()
        // Cancelled between the spawn and this call: nobody else will say so.
        if stop { cancel() }
    }

    func detachHelper() {
        cancellation.lock()
        helper = 0
        cancellation.unlock()
    }

    private func killHelper(_ pid: pid_t) {
        cancellation.lock()
        let live = helper == pid
        cancellation.unlock()
        if live { kill(pid, SIGKILL) }
    }

    public var isCancelled: Bool {
        cancellation.lock()
        defer { cancellation.unlock() }
        return cancelled
    }

    /// Runs to completion on the calling thread and reports how it ended.
    /// `report` is called from the libSystem callbacks, on that same thread.
    ///
    /// `matches` is called by a `.search` job and nobody else, once per batch,
    /// on that same thread. It is separate from `report` because the two mean
    /// different things — how far along, versus what was found — and a search
    /// that finds nothing still reports progress and still completes.
    ///
    /// `note` is a line for the log from an archive job — a member skipped,
    /// a helper that died — that no outcome code carries.
    public func run(
        report: @escaping (JobProgress) -> Void,
        matches: @escaping (SearchBatch) -> Void = { _ in },
        note: @escaping (String) -> Void = { _ in }
    ) -> FilaFailure {
        let tally = JobTally(job: self, report: report)
        do {
            if request.kind.isArchive { return try archive(report: report, note: note) }
            try perform(tally: tally, matches: matches)
            tally.flush()
            return FilaFailure(code: .success)
        } catch let failure as FilaFailure {
            // Cancellation points report cancellation themselves. A real
            // failure cleaning a temporary must remain visible even then.
            return failure
        } catch {
            return FilaFailure(code: .operationFailed)
        }
    }

    // MARK: - The work

    /// A compress or an extract runs in `fila-archive` — see
    /// `ArchiveHelperRun` — and only where a helper was configured. The
    /// in-process backend never reaches this: it runs the same job itself.
    private func archive(report: @escaping (JobProgress) -> Void, note: @escaping (String) -> Void) throws -> FilaFailure {
        guard let helper = operations.archiveHelper else {
            throw FilaFailure(code: .invalidRequest, systemError: ENOSYS)
        }
        guard request.archive != nil, request.destination != nil, !request.sources.isEmpty else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        // Settled here as well as in the helper, so a request that names
        // nothing fails with the errno rather than with a helper exit.
        for source in request.sources { _ = try FilaPath.canonical(source) }
        return try ArchiveHelperRun.run(
            helper: helper,
            task: ArchiveHelperTask(request: request, bootstrapRoot: operations.bootstrapRoot),
            job: self,
            report: report,
            note: note
        )
    }

    private func perform(tally: JobTally, matches: @escaping (SearchBatch) -> Void) throws {
        // Settle every path — both ends of every item — before touching any of
        // them. A job that copies over two files and then refuses the third has
        // already done the damage the guard exists to prevent, and the refusal
        // costs nothing if it comes first.
        let sources = try request.sources.map { source -> String in
            switch request.kind {
            case .move, .delete:
                // The two that destroy what they name, and the two the guard is
                // asked about.
                return try operations.resolveForDestruction(source, overrideGuard: request.overrideGuard)
            case .copy, .search:
                // A copy destroys nothing at the source and a search touches
                // nothing at all. Refusing to copy `/usr` somewhere, or to
                // search it, would make the app useless for the thing it is
                // for — so the guard applies to what an operation would
                // *replace* and never to what it reads.
                return try FilaPath.canonical(source)
            case .compress, .extract:
                preconditionFailure("archive jobs run in the helper — see run(report:matches:note:)")
            }
        }

        // Nothing below applies to a search: it has no destination to settle
        // and nothing at either end to overwrite.
        if request.kind == .search { return try search(sources, tally: tally, deliver: matches) }

        // One selected tree must not consume another selected source. Reject
        // duplicates and overlapping roots before any item can be changed.
        let sourceSet = Set(sources)
        guard sourceSet.count == sources.count else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        for source in sources {
            var parent = FilaPath.directory(of: source)
            while parent != source {
                guard !sourceSet.contains(parent) else {
                    throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: source)
                }
                if parent == "/" { break }
                parent = FilaPath.directory(of: parent)
            }
        }

        var targets: [String] = []
        if request.kind != .delete {
            let directory = try destinationDirectory()
            targets = try sources.map { try target(in: directory, for: $0) }
            guard Set(targets).count == targets.count else {
                throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: directory)
            }
        }

        for (index, source) in sources.enumerated() {
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
            tally.beginItem(source)
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
            switch request.kind {
            case .copy: try copy(source, to: targets[index], tally: tally)
            case .move: try move(source, to: targets[index], tally: tally)
            case .delete: try delete(source, tally: tally)
            case .search, .compress, .extract: break // Returned above.
            }
        }
    }

    /// Walks every root, streaming matches out as batches.
    ///
    /// The final batch goes out however this ends — finished, failed or
    /// cancelled — because it is what carries the limits the walk ran into, and
    /// a client that never received them would show a truncated list as a
    /// complete one.
    private func search(_ roots: [String], tally: JobTally, deliver: @escaping (SearchBatch) -> Void) throws {
        guard let query = request.query, !query.text.isEmpty else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        let search = TreeSearch(query: query, job: self, tally: tally, deliver: deliver)
        defer { search.flush() }
        for root in roots {
            if isCancelled { throw FilaFailure(code: .cancelled, path: root) }
            try search.run(root: root)
        }
    }

    private func destinationDirectory() throws -> String {
        guard let destination = request.destination else {
            throw FilaFailure(code: .invalidRequest)
        }
        // A destination is an existing directory, so its final symlink must
        // resolve too. Source item paths deliberately keep their final link.
        let directory = try operations.resolveForWrite(FilaPath.resolve(FilaPath.canonical(destination)))
        var metadata = stat()
        try filaCheck(directory) { lstat(directory, &metadata) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(code: .operationFailed, systemError: ENOTDIR, path: directory)
        }
        return directory
    }

    /// Where `source` lands, having settled what happens to anything already
    /// there.
    private func target(in directory: String, for source: String) throws -> String {
        // A destination inside its own source copies the tree into itself and
        // keeps going until the path runs out — filling the volume on the way.
        // `renameat` catches it with EINVAL; copyfile does not.
        guard source != directory, !FilaGuard.isAncestor(source, of: directory) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: directory)
        }

        let target = try operations.resolveForWrite(FilaPath.join(directory, FilaPath.name(of: source)))
        var sourceMetadata = stat()
        try filaCheck(source) { lstat(source, &sourceMetadata) }
        var targetMetadata = stat()
        guard lstat(target, &targetMetadata) == 0 else {
            guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: target) }
            return target
        }
        guard sourceMetadata.st_dev != targetMetadata.st_dev || sourceMetadata.st_ino != targetMetadata.st_ino else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: target)
        }
        guard request.overwrite else {
            throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: target)
        }
        // Overwriting is destroying whatever was there, so it is the guard's
        // business even though the client called it a copy.
        _ = try operations.resolveForDestruction(target, overrideGuard: request.overrideGuard)
        if targetMetadata.st_mode & S_IFMT == S_IFDIR {
            guard let entries = opendir(target) else { throw FilaFailure(errno: Darwin.errno, path: target) }
            defer { closedir(entries) }
            Darwin.errno = 0
            while let entry = readdir(entries) {
                let name = filaText(entry.pointee.d_name)
                guard name == "." || name == ".." else {
                    throw FilaFailure(code: .operationFailed, systemError: ENOTEMPTY, path: target)
                }
            }
            guard Darwin.errno == 0 else { throw FilaFailure(errno: Darwin.errno, path: target) }
        }
        return target
    }

    private func copy(_ source: String, to target: String, tally: JobTally) throws {
        // Publish only a complete copy. Cancellation or a failed read leaves
        // the previous destination intact, including when overwrite was approved.
        let temporary = try operations.resolveForWrite(
            FilaPath.join(FilaPath.directory(of: target), ".fila-copy-\(UUID().uuidString)")
        )
        do {
            // A clone is instant on APFS; copyfile handles other filesystems
            // and trees while keeping metadata and memory use bounded.
            let cloned = clonefile(source, temporary, UInt32(CLONE_NOFOLLOW)) == 0
            if !cloned { try copyTree(source, to: temporary, tally: tally) }
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
            // Like AtomicReplace, defer flags that would prohibit the publication
            // rename until the new item has reached its final name.
            var metadata = stat()
            try filaCheck(temporary) { lstat(temporary, &metadata) }
            let immovable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
            if metadata.st_flags & immovable != 0 {
                _ = try operations.resolveForWrite(temporary, changesInode: true)
                try filaCheck(temporary) { lchflags(temporary, metadata.st_flags & ~immovable) }
            }
            try filaCheck(target) { renamex_np(temporary, target, request.overwrite ? 0 : UInt32(RENAME_EXCL)) }
            if metadata.st_flags & immovable != 0 {
                try filaCheck(target) { lchflags(target, metadata.st_flags) }
            }
            if cloned { tally.finishedItem() }
        } catch {
            try discardTemporary(temporary)
            throw error
        }
    }

    /// Only this job's unpublished copy is made removable. removefile owns
    /// traversal; its pre-order callback handles flags and directory access.
    private func discardTemporary(_ path: String) throws {
        _ = try operations.resolveForWrite(path)
        guard let state = removefile_state_alloc() else { throw FilaFailure(errno: ENOMEM, path: path) }
        defer { removefile_state_free(state) }
        removefile_state_set(state, UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK), unsafeBitCast(filaDiscardCopy, to: UnsafeRawPointer.self))
        guard removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 || Darwin.errno == ENOENT else {
            throw FilaFailure(errno: Darwin.errno, path: path)
        }
    }

    private func move(_ source: String, to target: String, tally: JobTally) throws {
        if filaSameVolume(source, FilaPath.directory(of: target)) {
            try filaCheck(target) { renamex_np(source, target, request.overwrite ? 0 : UInt32(RENAME_EXCL)) }
            tally.finishedItem()
            return
        }
        // Across volumes there is no rename. Copy the whole thing, and remove
        // the original only once the copy has come back clean.
        try copy(source, to: target, tally: tally)
        if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
        try removeTree(source, tally: tally)
    }

    private func delete(_ source: String, tally: JobTally) throws {
        guard request.useTrash else { return try removeTree(source, tally: tally) }
        try moveIntoTrash(source, at: try trashDirectory(for: source))
        tally.finishedItem()
    }

    // MARK: - libSystem

    private func copyTree(_ source: String, to target: String, tally: JobTally) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(filaCopyProgress, to: UnsafeRawPointer.self)
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tally).toOpaque())

        // COPYFILE_ALL is what carries xattrs, ACLs, resource forks and BSD
        // flags across. COPYFILE_NOFOLLOW is the rule the whole project keeps:
        // copying a link copies the link, and a link at the destination is
        // replaced rather than written through. COPYFILE_RECURSIVE is set even
        // for a single file, so the per-item callbacks that drive progress fire
        // in both cases.
        let flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL
        let result = copyfile(source, target, state, copyfile_flags_t(flags))
        // What the callback saw comes first: it stopped the walk deliberately,
        // so the errno left behind is ECANCELED and says nothing useful.
        if let failure = tally.failure { throw failure }
        guard result == 0 else { throw FilaFailure(errno: Darwin.errno, path: source) }
    }

    private func removeTree(_ source: String, tally: JobTally) throws {
        let state = removefile_state_alloc()
        defer { removefile_state_free(state) }
        removefile_state_set(
            state,
            UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK),
            unsafeBitCast(filaRemoveProgress, to: UnsafeRawPointer.self)
        )
        removefile_state_set(
            state,
            UInt32(REMOVEFILE_STATE_CONFIRM_CONTEXT),
            Unmanaged.passUnretained(tally).toOpaque()
        )
        // REMOVEFILE_RECURSIVE alone: removefile never follows a symlink, so a
        // link is unlinked and whatever it pointed at is left alone.
        try filaCheck(source) { removefile(source, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) }
        if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
    }

    // MARK: - Trash

    /// `FilaTrash.directoryName` beneath the writable root, or the volume
    /// mount point for an unrestricted backend, created 0700 if it is not there.
    ///
    /// Reaching it is a `rename(2)`, which is why moving to the trash is
    /// instant and reversible — and also why the trash is per volume, because
    /// rename does not cross one. A read-only volume, or a source on a
    /// different volume from its trash, fails here with the errno the kernel
    /// gave, and the app turns that into the offer of a permanent delete. There
    /// is deliberately no fallback to a copy: a "move to trash" that quietly
    /// duplicates gigabytes is not what anybody asked for.
    private func trashDirectory(for path: String) throws -> String {
        // The *directory* the item is in, not the item: `statfs` follows
        // symlinks, and a dangling one — a normal thing to want to delete —
        // would fail here with ENOENT, while a live one would name the volume
        // it points at and lose the rename to EXDEV.
        var volume = statfs()
        let container = FilaPath.directory(of: path)
        guard statfs(container, &volume) == 0 else { throw FilaFailure(errno: Darwin.errno, path: container) }
        let base = try operations.trashBase(volumeMountPoint: filaText(volume.f_mntonname))
        let trash = try operations.resolveForWrite(FilaTrash.directory(under: base))
        if mkdir(trash, 0o700) != 0 {
            guard Darwin.errno == EEXIST else { throw FilaFailure(errno: Darwin.errno, path: trash) }
        }
        // A pre-existing link is not a trash directory. Never follow it while
        // publishing the renamed item.
        var metadata = stat()
        try filaCheck(trash) { lstat(trash, &metadata) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(errno: ENOTDIR, path: trash)
        }
        return trash
    }

    /// Renames the item into the trash under a name nothing else is using.
    ///
    /// Two deletes of the same name must both survive: the trash is the undo,
    /// and an undo that overwrote the previous one is not an undo. Picking a
    /// free name and then renaming into it does not achieve that, because the
    /// two are separate steps and POSIX `rename(2)` replaces what it finds —
    /// so a second delete landing in the gap destroys the first, silently and
    /// with no trash left to recover it from.
    ///
    /// `renamex_np(..., RENAME_EXCL)` closes the gap: the kernel checks and
    /// moves under one lock, and a name taken in the meantime comes back as
    /// `EEXIST` for the next suffix to try rather than as a lost file.
    private func moveIntoTrash(_ source: String, at directory: String) throws {
        let name = FilaPath.name(of: source)
        for suffix in 0 ..< 1_000 {
            let candidate = try operations.resolveForWrite(
                FilaPath.join(directory, suffix == 0 ? name : "\(name)-\(suffix)")
            )
            if renamex_np(source, candidate, UInt32(RENAME_EXCL)) == 0 {
                recordOrigin(source, on: candidate, keepingExisting: FilaPath.directory(of: source) == directory)
                return
            }
            // Anything else — a read-only volume, a cross-volume rename, an
            // immutable flag — is the real reason the delete failed, and the
            // app turns it into the offer of a permanent delete.
            guard Darwin.errno == EEXIST else { throw FilaFailure(errno: Darwin.errno, path: candidate) }
        }
        throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: FilaPath.join(directory, name))
    }

    /// Writes where the item came from onto the item itself, so Put Back needs
    /// no index that could drift from the directory. Best effort: the rename
    /// already succeeded, and an item that cannot carry the note is still in
    /// the trash — it just cannot be put back from there.
    ///
    /// Skipped for a file with another name: the attribute lives on the inode,
    /// and the other name may be outside the writable root.
    ///
    /// A note left from an earlier stay in the trash is replaced: the item was
    /// moved out by hand and deleted again from wherever it went, and that is
    /// where it belongs now. The one exception is an item trashed from inside
    /// the trash — it only moved within it, and its real origin is kept.
    private func recordOrigin(_ source: String, on trashed: String, keepingExisting: Bool) {
        var metadata = stat()
        guard lstat(trashed, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_nlink == 1 else { return }
        let options = XATTR_NOFOLLOW | (keepingExisting ? XATTR_CREATE : 0)
        _ = source.withCString { origin in
            setxattr(trashed, FilaTrash.originAttribute, origin, strlen(origin), 0, options)
        }
    }
}

private let filaDiscardCopy: removefile_callback_t = { _, path, _ in
    guard let path else { return Int32(REMOVEFILE_PROCEED) }
    var metadata = stat()
    if lstat(path, &metadata) == 0 {
        // A copied hard link must not make cleanup clear another name's flags.
        if metadata.st_mode & S_IFMT != S_IFDIR, metadata.st_nlink > 1 {
            return Int32(REMOVEFILE_PROCEED)
        }
        if metadata.st_flags != 0 { _ = lchflags(path, 0) }
        if metadata.st_mode & S_IFMT == S_IFDIR { _ = lchmod(path, metadata.st_mode | S_IRWXU) }
    }
    return Int32(REMOVEFILE_PROCEED)
}

/// Whether two paths sit on one device — which is to say whether a move is a
/// `renameat(2)` or a copy followed by a delete.
func filaSameVolume(_ first: String, _ second: String) -> Bool {
    var one = stat()
    var other = stat()
    guard lstat(first, &one) == 0, lstat(second, &other) == 0 else { return false }
    return one.st_dev == other.st_dev
}
