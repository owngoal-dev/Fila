import CRemoveFile
import Darwin
import FilaProtocol

public extension FileOperations {
    /// Only this job's unpublished copy is made removable. removefile owns
    /// traversal; its pre-order callback handles flags and directory access.
    func discardTemporary(_ path: String) throws {
        let path = try resolveForWrite(path)
        guard let state = removefile_state_alloc() else { throw FilaFailure(errno: ENOMEM, path: path) }
        defer { removefile_state_free(state) }
        removefile_state_set(
            state,
            UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK),
            unsafeBitCast(filaDiscardCopy, to: UnsafeRawPointer.self)
        )
        guard removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 || Darwin.errno == ENOENT else {
            throw FilaFailure(errno: Darwin.errno, path: path)
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
        if metadata.st_flags != 0 {
            _ = lchflags(path, 0)
        }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            _ = lchmod(path, metadata.st_mode | S_IRWXU)
        }
    }
    return Int32(REMOVEFILE_PROCEED)
}
