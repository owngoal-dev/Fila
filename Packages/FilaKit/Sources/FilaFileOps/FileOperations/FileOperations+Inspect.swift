import Darwin
import FilaProtocol
import Foundation

// Reading what is on disk: the `stat` → `FileNode` bridge every listing and
// every properties screen shares, and the four requests that only look.

public extension FileOperations {
    /// Everything the properties screen shows for one path.
    ///
    /// The path in the reply is the canonical one, because that is the string
    /// every decision here was made about — including the guard's verdict, and
    /// including the `lstat` that says whether this is a link or what it points
    /// at.
    func details(of path: String) throws -> FileDetails {
        let resolved = try FilaPath.canonical(path)
        var metadata = stat()
        guard lstat(resolved, &metadata) == 0 else {
            throw FilaFailure(errno: Darwin.errno, path: resolved)
        }
        return FileDetails(
            path: resolved,
            node: FileNode(name: FilaPath.name(of: resolved), metadata: metadata, at: AT_FDCWD, named: resolved),
            extendedAttributes: filaExtendedAttributeList(at: resolved),
            hasAccessControlList: filaHasAccessControlList(at: resolved),
            isDestructionProtected: isDestructionProtected(resolved)
        )
    }

    /// `statfs`, plus the `st_dev` that answers the question the browser
    /// actually has: same volume means `rename(2)` and `clonefile(2)` work,
    /// different volume means a copy and a separate trash.
    func volumeInfo(for path: String) throws -> VolumeInfo {
        let resolved = try FilaPath.canonical(path)
        var volume = statfs()
        guard statfs(resolved, &volume) == 0 else {
            throw FilaFailure(errno: Darwin.errno, path: resolved)
        }
        var metadata = stat()
        guard lstat(resolved, &metadata) == 0 else {
            throw FilaFailure(errno: Darwin.errno, path: resolved)
        }
        return VolumeInfo(
            mountPoint: filaText(volume.f_mntonname),
            deviceName: filaText(volume.f_mntfromname),
            filesystemType: filaText(volume.f_fstypename),
            totalByteCount: Int64(volume.f_blocks) * Int64(volume.f_bsize),
            availableByteCount: Int64(volume.f_bavail) * Int64(volume.f_bsize),
            isReadOnly: volume.f_flags & UInt32(MNT_RDONLY) != 0,
            deviceIdentifier: UInt64(UInt32(bitPattern: metadata.st_dev))
        )
    }

    /// `open(2)` as root, and that is all. Nothing in this module reads or
    /// writes a byte of the file — the descriptor goes back over XPC and the
    /// app talks to the kernel directly, which is what keeps the daemon's
    /// memory flat under launchd's 6 MB cap.
    func open(_ path: String, flags: Int32, mode: mode_t) throws -> Int32 {
        // O_TRUNC and O_CREAT can mutate even without a writable access mode.
        // No-follow also closes the final-link gap between this check and open.
        let writes = flags & (O_ACCMODE | O_CREAT | O_TRUNC | O_APPEND) != 0
        if writes, writableRoot != nil {
            let resolved = try resolveForWrite(path, changesInode: true)
            return try filaCheck(resolved) { Darwin.open(resolved, flags | O_NOFOLLOW, mode) }
        }
        let resolved = try FilaPath.canonical(path)
        // A read-only FIFO must never block the daemon's control queue.
        // Ordinary files ignore O_NONBLOCK; byte readers still check fstat's type.
        return try filaCheck(resolved) { Darwin.open(resolved, writes ? flags : flags | O_NONBLOCK, mode) }
    }

    /// One extended attribute's value.
    ///
    /// Capped, because a resource fork is an extended attribute and a resource
    /// fork can be megabytes: past the cap it is a file in disguise and the
    /// caller wants a descriptor, not a message.
    func extendedAttribute(_ name: String, at path: String) throws -> Data {
        let resolved = try FilaPath.canonical(path)
        let size = getxattr(resolved, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw FilaFailure(errno: Darwin.errno, path: resolved) }
        guard size <= FilaProtocol.maximumExtendedAttributeByteCount else {
            throw FilaFailure(code: .operationFailed, systemError: E2BIG, path: resolved)
        }
        guard size > 0 else { return Data() }

        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes {
            getxattr(resolved, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read >= 0 else { throw FilaFailure(errno: Darwin.errno, path: resolved) }
        return Data(value.prefix(read))
    }
}

// MARK: - stat, as the wire wants it

extension FileNode {
    /// Built from an `lstat` that has already happened, so the caller decides
    /// whether it walked a path or a directory descriptor. `directory`/`named`
    /// are only used to read a symlink's target, and only when this is one.
    init(name: String, metadata: stat, at directory: Int32, named entry: String) {
        let kind = FileKind(modeBits: metadata.st_mode)
        self.init(
            name: name,
            kind: kind,
            size: Int64(metadata.st_size),
            allocatedSize: Int64(metadata.st_blocks) * 512,
            modified: filaSeconds(metadata.st_mtimespec),
            created: filaSeconds(metadata.st_birthtimespec),
            accessed: filaSeconds(metadata.st_atimespec),
            mode: metadata.st_mode,
            ownerID: metadata.st_uid,
            groupID: metadata.st_gid,
            systemFlags: metadata.st_flags,
            linkCount: UInt64(metadata.st_nlink),
            inode: metadata.st_ino,
            link: kind == .symbolicLink ? filaReadSymbolicLink(directory, entry) : nil
        )
    }
}

/// Unix epoch seconds, which is what every timestamp on the wire is.
func filaSeconds(_ time: timespec) -> Double {
    Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}

/// Where a link points and what is there.
///
/// A nil `resolvedKind` means the link dangles — a normal thing to find on a
/// jailbroken filesystem, and a normal thing to want to delete, so it is a
/// state the browser shows rather than an error anyone reports.
func filaReadSymbolicLink(_ directory: Int32, _ entry: String) -> SymbolicLink? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBufferPointer { target in
        readlinkat(directory, entry, target.baseAddress, target.count - 1)
    }
    guard length >= 0 else { return nil }
    buffer[length] = 0

    var resolved = stat()
    let kind = fstatat(directory, entry, &resolved, 0) == 0 ? FileKind(modeBits: resolved.st_mode) : nil
    return SymbolicLink(target: String(cString: buffer), resolvedKind: kind)
}

/// Extended attribute names and sizes, never values.
func filaExtendedAttributeList(at path: String) -> [ExtendedAttribute] {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var names = [CChar](repeating: 0, count: size)
    let written = names.withUnsafeMutableBufferPointer { listxattr(path, $0.baseAddress, size, XATTR_NOFOLLOW) }
    guard written > 0 else { return [] }

    var attributes: [ExtendedAttribute] = []
    var start = 0
    for index in 0 ..< written where names[index] == 0 {
        if index > start {
            let name = String(cString: Array(names[start ..< index]) + [0])
            attributes.append(ExtendedAttribute(
                name: name,
                byteCount: Int64(max(0, getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)))
            ))
        }
        start = index + 1
    }
    return attributes
}

/// Whether the node carries an ACL. `acl_get_link_np` rather than
/// `acl_get_file` for the same reason everything else here uses the `l`
/// variant: the answer must be about the link, not about what it points at.
func filaHasAccessControlList(at path: String) -> Bool {
    guard let list = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
    acl_free(UnsafeMutableRawPointer(list))
    return true
}

/// A NUL-terminated C string held in a fixed-size struct field.
public func filaText(_ field: some Any) -> String {
    withUnsafeBytes(of: field) { raw in
        guard let base = raw.baseAddress else { return "" }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}
