import Foundation

/// Writable file archives. Read-only containers (for example RAR) are not
/// offered. Here rather than in `FilaFormats` because a `.compress` job names
/// its format on the wire.
public enum ArchiveFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case zip, tarZstd, tar, tarGzip, tarBzip2, tarXz, tarLzma, tarLzip, tarLz4

    public var filenameExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarZstd: return "tar.zst"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tarLzma: return "tar.lzma"
        case .tarLzip: return "tar.lz"
        case .tarLz4: return "tar.lz4"
        }
    }
}

public enum ZipCompression: String, Codable, Sendable, Hashable, CaseIterable {
    case balanced, smallest, store
}

/// One member of an archive an `.extract` job is asked for.
///
/// Matched by position, never by name: an archive may carry the same name
/// twice. The name rides along so the job can notice the archive changing
/// between the listing and the extraction, and refuse to hand over a member
/// the user never ticked.
public struct ArchiveSelection: Codable, Sendable, Hashable {
    public var index: Int64
    public var declaredPath: String

    public init(index: Int64, declaredPath: String) {
        self.index = index
        self.declaredPath = declaredPath
    }
}

/// How a zip's members are encrypted when a password is set. AES-256 is what
/// the format's own tools make today; ZipCrypto is weak and universally
/// readable, which is sometimes the point.
public enum ZipEncryption: String, Codable, Sendable, Hashable, CaseIterable {
    case aes256, zipCrypto
}

/// What a `.compress` or `.extract` job needs beyond its paths.
public struct ArchiveOptions: Codable, Sendable, Hashable {
    /// `.compress` only.
    public var format: ArchiveFormat
    public var zipCompression: ZipCompression
    public var encryption: ZipEncryption
    /// Encrypts a zip being written, decrypts one being read. Never logged.
    public var password: String?
    /// `.extract` only: the members to create, or nil for every member.
    public var members: [ArchiveSelection]?

    public init(
        format: ArchiveFormat = .zip,
        zipCompression: ZipCompression = .balanced,
        encryption: ZipEncryption = .aes256,
        password: String? = nil,
        members: [ArchiveSelection]? = nil
    ) {
        self.format = format
        self.zipCompression = zipCompression
        self.encryption = encryption
        self.password = password
        self.members = members
    }
}

/// What `filad` hands its archive helper on standard input, as one JSON
/// document. The helper is the one process in the package that both links
/// libarchive and runs as root, and this is the whole of what it is told.
public struct ArchiveHelperTask: Codable, Sendable {
    public var request: JobRequest
    /// The daemon's own install root, so the helper's guard agrees with the
    /// daemon's.
    public var bootstrapRoot: String

    public init(request: JobRequest, bootstrapRoot: String) {
        self.request = request
        self.bootstrapRoot = bootstrapRoot
    }
}

/// What the helper writes back, one JSON document per line on standard output.
///
/// `completed` is the last line; a helper that exits without one failed in a
/// way it could not report, and the daemon says so from the exit status.
public enum ArchiveHelperLine: Codable, Sendable, Hashable {
    case progress(JobProgress)
    /// A member skipped for a reason the outcome cannot carry — a name that
    /// escapes the destination, a device node. Logged by the daemon.
    case note(String)
    case completed(FilaFailure)
}
