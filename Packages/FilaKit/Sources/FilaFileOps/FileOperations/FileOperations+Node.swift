import Darwin
import FilaProtocol
import Foundation

// Creating a node applies its default attributes before returning it to the
// client. Moving a node preserves the metadata it already carries.

public extension FileOperations {
    /// Removes only an empty directory. The kernel's emptiness check and
    /// removal are one operation; a child created meanwhile is never deleted.
    func removeEmptyDirectory(at path: String) throws {
        let resolved = try resolveForDestruction(path)
        try filaCheck(resolved) { rmdir(resolved) }
    }

    /// mkdir, symlink, hardlink, or an empty regular file.
    ///
    /// An explicit `mode` keeps the caller's creation policy, such as a private
    /// workspace or an archive entry. Otherwise use the mobile/0777 defaults.
    /// Creation must stay in the writable root and fails with `EEXIST` rather
    /// than replacing anything.
    func create(_ template: NodeTemplate, at path: String, mode: mode_t? = nil) throws {
        let resolved = try resolveForWrite(path)
        switch template {
        case .directory:
            try filaCheck(resolved) { mkdir(resolved, mode ?? 0o700) }
        case .emptyFile:
            // O_EXCL, so "New File" can never truncate one that is already
            // there. A file manager that can destroy a file by creating one is
            // not a file manager.
            let descriptor = try filaCheck(resolved) {
                Darwin.open(resolved, O_CREAT | O_EXCL | O_WRONLY, mode ?? 0o600)
            }
            close(descriptor)
        case let .symbolicLink(target):
            try filaCheck(resolved) { symlink(target, resolved) }
        case let .hardLink(existing):
            // Canonicalised like every other path that reaches a syscall here:
            // a relative one would resolve against the daemon's own working
            // directory, which under launchd is `/`. A symlink target is the
            // one thing left alone, because a relative symlink is a real thing
            // a user means to make.
            // Linking changes the source inode too, so it cannot import an
            // outside inode under a writable name inside the root.
            let target = try resolveForWrite(existing)
            // No `AT_SYMLINK_FOLLOW`: a hard link to a symlink links the link,
            // which is the same rule the destructive operations follow.
            try filaCheck(resolved) { linkat(AT_FDCWD, target, AT_FDCWD, resolved, 0) }
            return // A hard link shares the source's existing metadata.
        }
        guard mode == nil else { return }
        do {
            try setAttributes(.newItemDefaults, at: resolved)
        } catch {
            // Only remove the node this call created. Never walk a directory
            // if another process has already put children inside it.
            if template == .directory {
                _ = rmdir(resolved)
            } else {
                _ = unlink(resolved)
            }
            throw error
        }
    }

    /// `renameat(2)` — the cheap move, and how the trash works.
    ///
    /// `exclusive` switches to `renamex_np(..., RENAME_EXCL)`, which fails with
    /// `EEXIST` rather than replacing what is at the destination. Callers that
    /// pick a free name and then rename into it want it: between the check and
    /// the rename another process can create that name, and POSIX `rename`
    /// destroys whatever it finds without a word. The kernel does the whole
    /// thing under one lock, so there is no window left to lose.
    ///
    /// The default is the POSIX behaviour, because replacing is what a move
    /// onto an existing file means. That default is only safe where the caller
    /// has already put the collision to the user — and not every caller does,
    /// so a caller that has not is a caller that should be passing `exclusive`.
    func rename(
        _ source: String,
        to destination: String,
        exclusive: Bool = false,
        overrideGuard: Bool = false
    ) throws {
        let from = try resolveForDestruction(source, overrideGuard: overrideGuard)
        let to = try resolveForWrite(destination)

        // `rename(2)` replaces whatever is at the destination without a word,
        // so a destination that exists is as destructive as the source and gets
        // asked about the same way. An exclusive rename replaces nothing — it
        // fails instead — so there is nothing there for the guard to refuse.
        if !exclusive, filaExists(to) {
            _ = try resolveForDestruction(to, overrideGuard: overrideGuard)
        }
        try filaCheck(from) {
            exclusive
                ? renamex_np(from, to, UInt32(RENAME_EXCL))
                : renameat(AT_FDCWD, from, AT_FDCWD, to)
        }
    }
}
