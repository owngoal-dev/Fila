import Foundation

/// What `lstat` found. Never what the link points at — see `SymbolicLink`.
public enum FileKind: UInt64, Sendable, Hashable {
    case unknown = 0
    case regular = 1
    case directory = 2
    case symbolicLink = 3
    case fifo = 4
    case socket = 5
    case blockDevice = 6
    case characterDevice = 7

    /// From `st_mode`'s type bits. The one place the `S_IF*` constants are read,
    /// so nothing downstream has to know them.
    public init(modeBits: mode_t) {
        switch modeBits & S_IFMT {
        case S_IFREG: self = .regular
        case S_IFDIR: self = .directory
        case S_IFLNK: self = .symbolicLink
        case S_IFIFO: self = .fifo
        case S_IFSOCK: self = .socket
        case S_IFBLK: self = .blockDevice
        case S_IFCHR: self = .characterDevice
        default: self = .unknown
        }
    }
}

/// Where a symlink points, and what is there.
///
/// `resolvedKind` is nil when the link is broken, which is a state the browser
/// shows rather than an error: a dangling link is a normal thing to find on a
/// jailbroken filesystem and a normal thing to want to delete.
public struct SymbolicLink: Sendable, Hashable {
    public var target: String
    public var resolvedKind: FileKind?

    public init(target: String, resolvedKind: FileKind?) {
        self.target = target
        self.resolvedKind = resolvedKind
    }

    public var isBroken: Bool {
        resolvedKind == nil
    }
}

/// One entry as a listing reports it: an `lstat` plus the name.
///
/// Deliberately a value with no path in it. A page carries 512 of these and the
/// directory they came from is known once, by the caller that asked.
public struct FileNode: Sendable, Hashable {
    public var name: String
    public var kind: FileKind
    /// `st_size`: what the file claims. For a directory this is the directory's
    /// own size, not its contents' — computing that is a walk, and a walk is
    /// the caller's decision, never a side effect of listing.
    public var size: Int64
    /// `st_blocks * 512`: what it costs. Differs from `size` for sparse files
    /// and for anything APFS cloned or compressed, and users of a file manager
    /// on a 64 GB phone care about the difference.
    public var allocatedSize: Int64
    public var modified: Double
    public var created: Double
    public var accessed: Double
    /// `st_mode`, type bits included.
    public var mode: mode_t
    public var ownerID: uid_t
    public var groupID: gid_t
    /// `st_flags`: `uchg`, `schg`, `hidden`, `uappnd`. An immutable flag is the
    /// usual reason a delete fails with EPERM as root, so it has to be visible.
    public var systemFlags: UInt32
    public var linkCount: UInt64
    public var inode: UInt64
    /// Present only when `kind == .symbolicLink`.
    public var link: SymbolicLink?

    public init(
        name: String,
        kind: FileKind,
        size: Int64,
        allocatedSize: Int64,
        modified: Double,
        created: Double,
        accessed: Double,
        mode: mode_t,
        ownerID: uid_t,
        groupID: gid_t,
        systemFlags: UInt32,
        linkCount: UInt64,
        inode: UInt64,
        link: SymbolicLink? = nil
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.mode = mode
        self.ownerID = ownerID
        self.groupID = groupID
        self.systemFlags = systemFlags
        self.linkCount = linkCount
        self.inode = inode
        self.link = link
    }

    /// Dotfile, or the BSD `UF_HIDDEN` flag Finder and Filza both honour.
    public var isHidden: Bool {
        name.hasPrefix(".") || systemFlags & UInt32(UF_HIDDEN) != 0
    }

    /// Locked against modification by `uchg` or `schg`. The daemon runs as root,
    /// so this — not permissions — is what usually stops a delete.
    public var isImmutable: Bool {
        systemFlags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
    }

    /// A directory, or a link that resolves to one: what the browser navigates
    /// into. The distinction between the two belongs here and nowhere else.
    public var isNavigable: Bool {
        kind == .directory || link?.resolvedKind == .directory
    }
}

/// One extended attribute, named and sized. The value is fetched separately —
/// a resource fork is an xattr, and a resource fork can be megabytes.
public struct ExtendedAttribute: Sendable, Hashable {
    public var name: String
    public var byteCount: Int64

    public init(name: String, byteCount: Int64) {
        self.name = name
        self.byteCount = byteCount
    }
}

/// Everything the properties screen shows for one path.
public struct FileDetails: Sendable, Hashable {
    /// The path as the daemon resolved it — `realpath(3)` where the file
    /// exists, so `/var/mobile` reads back as `/private/var/mobile`. Every
    /// decision the daemon made was made about this string, not the one the
    /// client sent.
    public var path: String
    public var node: FileNode
    public var extendedAttributes: [ExtendedAttribute]
    public var hasAccessControlList: Bool
    /// The guard's verdict, computed by its one owner and shipped so the UI can
    /// grey a menu item out. The app is untrusted: this is a courtesy, and the
    /// daemon checks again when the operation actually arrives.
    public var isDestructionProtected: Bool

    public init(
        path: String,
        node: FileNode,
        extendedAttributes: [ExtendedAttribute],
        hasAccessControlList: Bool,
        isDestructionProtected: Bool
    ) {
        self.path = path
        self.node = node
        self.extendedAttributes = extendedAttributes
        self.hasAccessControlList = hasAccessControlList
        self.isDestructionProtected = isDestructionProtected
    }
}

/// `statfs` for the volume a path lives on.
///
/// `deviceIdentifier` is what answers the question the browser actually has:
/// two paths on the same device move with `rename(2)` and can be cloned; two
/// paths on different devices need a copy, and the trash needs one per volume.
public struct VolumeInfo: Sendable, Hashable {
    public var mountPoint: String
    public var deviceName: String
    public var filesystemType: String
    public var totalByteCount: Int64
    public var availableByteCount: Int64
    public var isReadOnly: Bool
    public var deviceIdentifier: UInt64

    public init(
        mountPoint: String,
        deviceName: String,
        filesystemType: String,
        totalByteCount: Int64,
        availableByteCount: Int64,
        isReadOnly: Bool,
        deviceIdentifier: UInt64
    ) {
        self.mountPoint = mountPoint
        self.deviceName = deviceName
        self.filesystemType = filesystemType
        self.totalByteCount = totalByteCount
        self.availableByteCount = availableByteCount
        self.isReadOnly = isReadOnly
        self.deviceIdentifier = deviceIdentifier
    }
}

/// What `createNode` is asked to make.
///
/// A hard link and a symlink differ by one syscall and by what they mean when
/// the target moves, so they are separate cases rather than a flag.
public enum NodeTemplate: Sendable, Hashable {
    case directory
    case emptyFile
    case symbolicLink(target: String)
    case hardLink(existing: String)
}

/// What `setAttributes` changes. Every field is optional and nil means "leave
/// it": the properties screen edits one row at a time, and a write that carried
/// the whole struct would race with anything else touching the file.
public struct AttributeChange: Sendable, Hashable {
    /// New user files belong to mobile, including when filad creates them.
    /// The local backend keeps its own identity (also mobile on a device).
    public static var newItemDefaults: Self {
        Self(mode: 0o777, ownerID: geteuid() == 0 ? 501 : getuid(), groupID: geteuid() == 0 ? 501 : getgid())
    }

    public var mode: mode_t?
    public var ownerID: uid_t?
    public var groupID: gid_t?
    public var modified: Double?
    public var accessed: Double?
    public var systemFlags: UInt32?
    /// A nil value removes the attribute; a non-nil one sets it.
    public var extendedAttribute: (name: String, value: Data?)?
    /// Apply to every entry beneath the path as well. Owner and mode changes on
    /// a tree are the one bulk edit users genuinely need; anything larger is a
    /// job.
    public var isRecursive: Bool

    public init(
        mode: mode_t? = nil,
        ownerID: uid_t? = nil,
        groupID: gid_t? = nil,
        modified: Double? = nil,
        accessed: Double? = nil,
        systemFlags: UInt32? = nil,
        extendedAttribute: (name: String, value: Data?)? = nil,
        isRecursive: Bool = false
    ) {
        self.mode = mode
        self.ownerID = ownerID
        self.groupID = groupID
        self.modified = modified
        self.accessed = accessed
        self.systemFlags = systemFlags
        self.extendedAttribute = extendedAttribute
        self.isRecursive = isRecursive
    }

    public static func == (lhs: AttributeChange, rhs: AttributeChange) -> Bool {
        lhs.mode == rhs.mode && lhs.ownerID == rhs.ownerID && lhs.groupID == rhs.groupID
            && lhs.modified == rhs.modified && lhs.accessed == rhs.accessed
            && lhs.systemFlags == rhs.systemFlags && lhs.isRecursive == rhs.isRecursive
            && lhs.extendedAttribute?.name == rhs.extendedAttribute?.name
            && lhs.extendedAttribute?.value == rhs.extendedAttribute?.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mode)
        hasher.combine(ownerID)
        hasher.combine(groupID)
        hasher.combine(modified)
        hasher.combine(accessed)
        hasher.combine(systemFlags)
        hasher.combine(extendedAttribute?.name)
        hasher.combine(extendedAttribute?.value)
        hasher.combine(isRecursive)
    }
}
