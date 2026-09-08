import FilaProtocol
import Foundation

/// One member of an archive, as libarchive's header for it reports.
///
/// The name is kept exactly as the archive declares it and is never joined to
/// anything: `relativePath` is the only form that may be appended to a
/// destination directory, and it is nil for every name that could land the
/// write somewhere the user did not choose. Keeping both is deliberate — a
/// listing has to show what is actually inside a file the user downloaded,
/// including the entry named `../../etc/passwd`, and refusing to extract it is
/// a different decision from refusing to admit it exists.
public struct ArchiveEntry: Sendable, Hashable {
    /// The name the archive claims, decoded as UTF-8. **Display only.**
    public var declaredPath: String

    /// `.regular`, `.directory`, `.symbolicLink` — or one of the device kinds,
    /// which a tar can carry and which this app never creates.
    public var kind: FileKind

    /// Nil when the archive records no size. A lone gzip has no directory and
    /// therefore no length until it has been decompressed, and answering
    /// "unknown" costs nothing next to inflating a gigabyte to fill in a
    /// column.
    public var byteCount: Int64?

    /// The permission bits with the type bits included, as the archive recorded
    /// them. libarchive fills in a plausible default for formats that carry no
    /// mode, so this is never zero.
    public var mode: mode_t

    public var modified: Date?

    /// Where a symlink entry points. The target is as attacker-controlled as
    /// the name — see the extraction ordering in the browser.
    public var linkTarget: String?

    /// The member this entry is a hard link to, when it is one. Such an entry
    /// carries no bytes of its own, and Fila refuses to create it: a hard link
    /// is a second name for a file that already exists, and letting an archive
    /// choose that file is letting it choose what gets written.
    public var hardLinkTarget: String?

    /// The member's bytes need a password. Listing still works — a zip's
    /// names and sizes are in the clear — so the browser can ask before it
    /// starts an extraction rather than after one fails.
    public var isEncrypted = false

    public var isDirectory: Bool {
        kind == .directory
    }

    /// A tar's explicit `.` entry describes the extraction root, not a child.
    public var isRootDirectory: Bool {
        isDirectory && !declaredPath.isEmpty && !declaredPath.hasPrefix("/")
            && declaredPath.split(separator: "/").allSatisfy { $0 == "." }
    }

    public var isFinderMetadata: Bool {
        ArchivePath.isFinderMetadata(declaredPath)
    }

    public var isSymbolicLink: Bool {
        kind == .symbolicLink
    }

    /// The permission bits an extractor may apply — the low nine, and no more.
    ///
    /// `mode` keeps whatever the archive recorded, this drops setuid, setgid and
    /// the sticky bit on the way out. An archive is a file the user downloaded,
    /// and on this device the thing that creates its members runs as root: an
    /// archive that can plant a setuid-root binary merely by being extracted is
    /// a root shell for whoever built it. A user who genuinely wants those bits
    /// can set them afterwards, deliberately, on one file.
    public var permissions: mode_t {
        mode & 0o777
    }

    /// The last path component, for a listing that shows a name rather than a
    /// path.
    public var name: String {
        (declaredPath as NSString).lastPathComponent
    }

    /// `declaredPath` as a relative path that cannot climb out of a destination
    /// directory, or nil when it is not one.
    ///
    /// Nil for an absolute name, for any name with a `..` component in it, and
    /// for a name that is empty once `.` components are dropped. That is a
    /// *refusal*, not a repair: an entry called `../../etc/passwd` extracted as
    /// `etc/passwd` is a file the user never asked for, quietly, and on a device
    /// where the destination may be anywhere the difference matters.
    public var relativePath: String? {
        ArchivePath.validated(declaredPath)
    }
}
