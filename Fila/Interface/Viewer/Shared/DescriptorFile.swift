import FilaClient
import FilaProtocol
import Foundation

/// A descriptor `filad` opened as root, and the reads a viewer does over it.
///
/// The daemon hands the descriptor back and forgets it, so every byte a viewer
/// shows is read here, in the app, straight from the kernel. That is the whole
/// design, and it is also why this type owns `close(2)`: descriptors are a real
/// per-process resource, and a browsing session that leaks one per opened file
/// dies of `EMFILE` long before it runs out of memory.
///
/// Every read is `pread(2)` — never `read(2)` plus a seek. The offset lives in
/// the argument rather than in the descriptor, so a windowed viewer scrolling
/// backwards and a background prefetch cannot corrupt each other's position.
final class DescriptorFile {
    /// `st_size` at open. A viewer that windows over a file needs the size
    /// before it has read a byte of it, which is the only reason to keep it.
    let byteCount: Int64

    private let descriptor: Int32
    private var isClosed = false

    init(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw ViewerFailure.readFailed(failure)
        }
        self.descriptor = descriptor
        byteCount = Int64(status.st_size)
    }

    static func open(
        _ path: String,
        flags: Int32 = O_RDONLY,
        mode: mode_t = 0o644,
        link: DaemonLink
    ) async throws -> DescriptorFile {
        try DescriptorFile(descriptor: await link.open(path, flags: flags, mode: mode))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    deinit { close() }

    /// Up to `count` bytes at `offset`. A short result means end of file and
    /// nothing else: `pread` returning less than asked mid-file is legal, so the
    /// loop is not optional.
    func read(at offset: Int64, count: Int) throws -> Data {
        guard !isClosed else { throw ViewerFailure.readFailed(EBADF) }
        guard offset >= 0, count >= 0 else { throw ViewerFailure.readFailed(EINVAL) }
        guard count > 0, offset < byteCount else { return Data() }
        let count = min(count, Int(byteCount - offset))
        var buffer = Data(count: count)
        var filled = 0
        try buffer.withUnsafeMutableBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            while filled < count {
                let got = pread(descriptor, base + filled, count - filled, off_t(offset) + off_t(filled))
                if got < 0 {
                    if errno == EINTR { continue }
                    throw ViewerFailure.readFailed(errno)
                }
                if got == 0 { break }
                filled += got
            }
        }
        // Re-wrapped rather than returned as a slice: a `Data` slice keeps the
        // parent's indices, and every parser downstream of here counts from
        // zero.
        return Data(buffer.prefix(filled))
    }

    /// The whole file, or a refusal. Loading is capped because the alternative
    /// is a viewer that jetsams the app on a file the user only wanted to look
    /// at — see `ViewerLimits`.
    func readAll(limit: Int64) throws -> Data {
        guard byteCount <= limit else { throw ViewerFailure.tooLarge(byteCount: byteCount, limit: limit) }
        let data = try read(at: 0, count: Int(byteCount))
        var current = stat()
        guard fstat(descriptor, &current) == 0 else { throw ViewerFailure.readFailed(errno) }
        guard data.count == byteCount, current.st_size == byteCount else { throw ViewerFailure.readFailed(EIO) }
        return data
    }

    /// Write `data` from offset zero. Only ever used on a freshly created
    /// `O_EXCL` temporary — never on a file the user already has, which is what
    /// `AtomicSave` exists to guarantee.
    func write(_ data: Data) throws {
        guard !isClosed else { throw ViewerFailure.writeFailed(EBADF) }
        var written = 0
        try data.withUnsafeBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            while written < data.count {
                let put = pwrite(descriptor, base + written, data.count - written, off_t(written))
                if put < 0 {
                    if errno == EINTR { continue }
                    throw ViewerFailure.writeFailed(errno)
                }
                if put == 0 { throw ViewerFailure.writeFailed(ENOSPC) }
                written += put
            }
        }
        // Surface delayed write failures before the temporary is published.
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw ViewerFailure.writeFailed(errno) }
        }
    }

    /// A `dup(2)` of the descriptor, for a framework that insists on owning one.
    ///
    /// `AVFoundation` reads an asset on its own threads for as long as the
    /// player lives, which is not the same lifetime as the screen that opened
    /// the file — so it gets a descriptor of its own rather than borrowing this
    /// one and reading a number that has since been reused.
    func duplicate() throws -> Int32 {
        guard !isClosed else { throw ViewerFailure.readFailed(EBADF) }
        let copy = dup(descriptor)
        guard copy >= 0 else { throw ViewerFailure.readFailed(errno) }
        return copy
    }
}

/// Anything a format reader can read bytes out of.
///
/// Two implementations and no more: the file itself, and the decompressed member
/// of an outer archive. A `.deb` is an `ar` holding a gzip holding a tar, and
/// without this seam the nested case would be a second copy of every parser.
/// It is also what lets the parsers be exercised against a `Data` with no daemon
/// anywhere in the picture.
protocol ByteSource {
    var byteCount: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

extension DescriptorFile: ByteSource {}

struct DataByteSource: ByteSource {
    let data: Data

    var byteCount: Int64 { Int64(data.count) }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
        let start = Int(offset)
        return data.subdata(in: start ..< start + min(count, data.count - start))
    }
}

/// The ceilings the viewers refuse above, in one place so they can be argued
/// about together rather than rediscovered one viewer at a time.
enum ViewerLimits {
    /// A text file above this is shown from its head with editing refused.
    /// Editing wants the whole thing in memory — every save rewrites every
    /// byte — and the text engine lays out the whole string, so the ceiling is
    /// the text view's long before it is the phone's.
    static let editableTextByteCount: Int64 = 4 * 1_024 * 1_024

    /// How much of an over-sized text file is shown before the tail is cut.
    static let textPreviewByteCount: Int64 = 1 * 1_024 * 1_024

    /// Above this a text file is shown with no grammar. Tree-sitter parses the
    /// whole string before the first line is drawn, and on the oldest hardware
    /// this app supports that stall is all the grammar contributes to a file
    /// nobody opened for its syntax.
    static let highlightedTextByteCount = 512 * 1_024

    /// A property list is parsed whole by `PropertyListSerialization`; there is
    /// no streaming plist parser and writing one is not worth it.
    static let propertyListByteCount: Int64 = 32 * 1_024 * 1_024

    /// Images and PDFs are handed to ImageIO and PDFKit as `Data`, so they are
    /// resident whole while the screen is up. The cap only has to stop something
    /// that is not really a document from being loaded as one.
    static let inMemoryDocumentByteCount: Int64 = 128 * 1_024 * 1_024

    /// What an extraction may materialise in the app's own container. Media no
    /// longer counts against it — a player reads its file through the descriptor
    /// and copies nothing — so this is the archive reader's ceiling alone.
    static let containerCopyByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024

    /// Mach-O load commands and an archive's directory are metadata; anything
    /// claiming more than this is corrupt or hostile.
    static let structureByteCount: Int64 = 16 * 1_024 * 1_024
}

enum ViewerFailure: LocalizedError {
    case readFailed(Int32)
    case writeFailed(Int32)
    case tooLarge(byteCount: Int64, limit: Int64)
    case unsupportedContent(String)

    var errorDescription: String? {
        switch self {
        case let .readFailed(code):
            return String(
                format: String(localized: "Could not read the file: %@."),
                String(cString: strerror(code))
            )
        case let .writeFailed(code):
            return String(
                format: String(localized: "Could not write the file: %@."),
                String(cString: strerror(code))
            )
        case let .tooLarge(byteCount, limit):
            return String(
                format: String(localized: "This file is too large (%@). The viewer supports files up to %@."),
                FilePresentation.byteLabel(byteCount),
                FilePresentation.byteLabel(limit)
            )
        case let .unsupportedContent(reason):
            return reason
        }
    }
}
