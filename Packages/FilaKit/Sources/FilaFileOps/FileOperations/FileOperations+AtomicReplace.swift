import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// Put a temporary the client has finished writing in place of `target`.
    ///
    /// Publish a completed regular file without truncating the old one. Flush
    /// the temporary before the atomic directory-entry swap; this does not
    /// promise durability against every storage or power failure.
    ///
    /// The known cost is taken knowingly: `rename` replaces the inode, so hard
    /// links to the old file keep the old content and a process holding it open
    /// never sees the new bytes. The alternative — `O_TRUNC` over the original
    /// — can destroy a file the user has no copy of.
    ///
    /// Alone among the destructive operations this takes no override. Every
    /// node the guard protects is a directory, so a replace of one is not a
    /// save the user meant to force — it is a client bug, and there is nothing
    /// to release.
    func replaceItem(at target: String, withTemporary temporary: String, permissions: mode_t? = nil) throws {
        let destination = try resolveForDestruction(target)
        // The temporary is *moved away* by the rename below, which is the act
        // the guard exists to forbid — and every protected node has an
        // unprotected sibling to name as the target. Guarding only the
        // destination would make this the way to move `/usr` somewhere.
        let source = try resolveForDestruction(temporary)

        // `rename(2)` is atomic within a directory and nowhere else. A caller
        // that put its temporary somewhere else got the one property this
        // operation exists for wrong, and has to find that out rather than
        // receive a copy that can be interrupted halfway.
        guard FilaPath.directory(of: source) == FilaPath.directory(of: destination) else {
            throw FilaFailure(code: .invalidRequest, systemError: EXDEV, path: temporary)
        }

        let descriptor = Darwin.open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw FilaFailure(errno: errno, path: source) }
        defer { close(descriptor) }
        var staged = stat()
        guard fstat(descriptor, &staged) == 0 else { throw FilaFailure(errno: errno, path: source) }
        guard staged.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: EINVAL, path: source) }

        var found = stat()
        let exists = lstat(destination, &found) == 0
        if !exists, errno != ENOENT {
            throw FilaFailure(errno: errno, path: destination)
        }
        let original = exists ? found : nil
        if let original {
            // A directory at the name cannot be published over, and the
            // metadata copy below reaches that fact first: `copyfile(3)` from
            // a directory to a regular file fails with EINVAL, which reads as
            // a malformed request rather than as what is in the way. Report
            // the errno the `rename` itself would have produced — the one the
            // client turns into `notEmpty` — while both sides are untouched.
            guard original.st_mode & S_IFMT != S_IFDIR else {
                throw FilaFailure(errno: EISDIR, path: destination)
            }
            // Metadata is written to the temporary before publication. It
            // must not share an inode with a name outside the writable root.
            _ = try resolveForWrite(source, changesInode: true)
            // ACLs and extended attributes through `copyfile(3)`, because a resource
            // fork is an extended attribute and can be megabytes — this streams
            // it and a hand-written loop would hold it.
            try filaCheck(destination) {
                copyfile(destination, source, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW))
            }
            // Owner before mode: chown clears setuid and setgid.
            try filaCheck(source) { lchown(source, original.st_uid, original.st_gid) }
            try filaCheck(source) { lchmod(source, original.st_mode & 0o7777) }
            var times = [
                filaTimeValue(filaSeconds(original.st_atimespec)),
                filaTimeValue(filaSeconds(original.st_mtimespec)),
            ]
            try filaCheck(source) { lutimes(source, &times) }
        } else if permissions == nil {
            _ = try resolveForWrite(source, changesInode: true)
            try filaApplyAttributes(.newItemDefaults, to: source)
        }

        if let permissions {
            _ = try resolveForWrite(source, changesInode: true)
            try filaCheck(source) { lchmod(source, permissions) }
        }

        while fsync(descriptor) != 0 {
            if errno != EINTR {
                throw FilaFailure(errno: errno, path: source)
            }
        }
        try filaCheck(destination) { renameat(AT_FDCWD, source, AT_FDCWD, destination) }

        // BSD flags go on afterwards, to the file at its new name: `uchg` on
        // the temporary would refuse the very rename that puts it in place. An
        // original that was already immutable fails the rename above with
        // EPERM, which is the errno the app needs to offer clearing the flag.
        if let original, original.st_flags != 0 {
            try filaCheck(destination) { lchflags(destination, original.st_flags) }
        }
    }
}
