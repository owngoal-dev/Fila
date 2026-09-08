import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// Mode, owner, group, times, BSD flags and one extended attribute, applied
    /// to a path and — when the change says so — to everything beneath it.
    ///
    /// Metadata writes obey the same daemon write boundary as file contents.
    /// The destruction guard does not apply because the node remains in place.
    func setAttributes(_ change: AttributeChange, at path: String) throws {
        let resolved = try resolveForWrite(path, changesInode: true)
        var metadata = stat()
        guard lstat(resolved, &metadata) == 0 else {
            throw FilaFailure(errno: Darwin.errno, path: resolved)
        }
        try filaApplyAttributes(change, to: resolved)

        // A recursive change on anything that is not a directory has already
        // been applied in full — including on a symlink, which is not followed
        // into whatever tree it points at.
        guard change.isRecursive, metadata.st_mode & S_IFMT == S_IFDIR else { return }
        try filaApplyAttributesBeneath(change, of: resolved, operations: self)
    }
}

/// One node, and every call is the `l` variant.
///
/// `FilaPath.canonical` resolves the parent and leaves the last component
/// alone, so the leaf may still be a symlink — and changing the mode of a
/// link's target when the user asked about the link is the same class of
/// mistake as deleting the wrong file.
func filaApplyAttributes(_ change: AttributeChange, to path: String) throws {
    if change.ownerID != nil || change.groupID != nil {
        // `(uid_t)-1` is chown's "leave this one alone".
        let owner = change.ownerID ?? uid_t.max
        let group = change.groupID ?? gid_t.max
        try filaCheck(path) { lchown(path, owner, group) }
    }

    // After the chown, which clears setuid and setgid.
    if let mode = change.mode {
        try filaCheck(path) { lchmod(path, mode) }
    }

    if change.modified != nil || change.accessed != nil {
        var current = stat()
        guard lstat(path, &current) == 0 else { throw FilaFailure(errno: Darwin.errno, path: path) }
        var times = [
            filaTimeValue(change.accessed ?? filaSeconds(current.st_atimespec)),
            filaTimeValue(change.modified ?? filaSeconds(current.st_mtimespec)),
        ]
        try filaCheck(path) { lutimes(path, &times) }
    }

    if let attribute = change.extendedAttribute {
        if let value = attribute.value {
            try filaCheck(path) {
                value.withUnsafeBytes {
                    setxattr(path, attribute.name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
            }
        } else {
            try filaCheck(path) { removexattr(path, attribute.name, XATTR_NOFOLLOW) }
        }
    }

    // Flags last. `uchg` and `schg` refuse every change above once they are
    // set, so setting them first would fail the rest of the same request.
    if let systemFlags = change.systemFlags {
        try filaCheck(path) { lchflags(path, systemFlags) }
    }
}

/// A tree deeper than this is a hand-built loop, not a filesystem — and one
/// open descriptor per level is what makes the depth worth bounding at all.
private let filaMaximumWalkDepth = 256

/// The recursive variant: an explicit stack of open directories, one level at a
/// time.
///
/// Not a collected list of paths, and not `fts(3)`: both hold a whole directory
/// level at once, and a single directory on a device can carry 100k entries —
/// inside a daemon launchd kills at 6 MB. What is held here is one `DIR *` and
/// one path string per level of depth, and nothing whatever per entry.
private func filaApplyAttributesBeneath(_ change: AttributeChange, of root: String, operations: FileOperations) throws {
    var stack: [(handle: UnsafeMutablePointer<DIR>, path: String)] = []
    defer { for level in stack { closedir(level.handle) } }

    func descend(into path: String) throws {
        guard stack.count < filaMaximumWalkDepth else {
            throw FilaFailure(code: .operationFailed, systemError: ELOOP, path: path)
        }
        guard let handle = opendir(path) else { throw FilaFailure(errno: Darwin.errno, path: path) }
        stack.append((handle, path))
    }

    try descend(into: root)
    while let level = stack.last {
        // NULL is the end of this level or an I/O error on it, and skipping the
        // rest of a directory in silence is how half a tree ends up with the
        // old owner.
        Darwin.errno = 0
        guard let record = readdir(level.handle) else {
            let code = Darwin.errno
            guard code == 0 else { throw FilaFailure(errno: code, path: level.path) }
            closedir(level.handle)
            stack.removeLast()
            continue
        }
        guard let child = filaChild(record, in: dirfd(level.handle)) else { continue }
        let path = try operations.resolveForWrite(FilaPath.join(level.path, child.name), changesInode: true)

        try filaApplyAttributes(change, to: path)
        // Real directories only. Following a link here would let one `../../..`
        // inside the tree turn a chown of a folder into a chown of the device.
        if child.metadata.st_mode & S_IFMT == S_IFDIR { try descend(into: path) }
    }
}

func filaTimeValue(_ seconds: Double) -> timeval {
    let whole = seconds.rounded(.down)
    return timeval(
        tv_sec: __darwin_time_t(whole),
        tv_usec: __darwin_suseconds_t((seconds - whole) * 1_000_000)
    )
}
