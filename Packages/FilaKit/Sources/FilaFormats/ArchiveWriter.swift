import FilaFileOps
import FilaProtocol
import Foundation
import LibArchive

extension ArchiveFormat {
    fileprivate func configure(_ handle: OpaquePointer, zipCompression: ZipCompression, encryption: ZipEncryption?) -> Int32 {
        if self == .zip {
            let status = archive_write_set_format_zip(handle)
            guard status == ARCHIVE_OK else { return status }
            let options = zipCompression.options + (encryption.map { "," + $0.options } ?? "")
            return archive_write_set_options(handle, options)
        }
        let status = archive_write_set_format_pax_restricted(handle)
        guard status == ARCHIVE_OK else { return status }
        let filter: Int32
        let options: String
        switch self {
        case .tar: return ARCHIVE_OK
        case .tarZstd:
            filter = archive_write_add_filter_zstd(handle)
            options = "zstd:compression-level=22,zstd:threads=1"
        case .tarGzip:
            filter = archive_write_add_filter_gzip(handle)
            options = "gzip:compression-level=9"
        case .tarBzip2:
            filter = archive_write_add_filter_bzip2(handle)
            options = "bzip2:compression-level=9"
        case .tarXz:
            filter = archive_write_add_filter_xz(handle)
            options = "xz:compression-level=9,xz:threads=1"
        case .tarLzma:
            filter = archive_write_add_filter_lzma(handle)
            options = "lzma:compression-level=9"
        case .tarLzip:
            filter = archive_write_add_filter_lzip(handle)
            options = "lzip:compression-level=9"
        case .tarLz4:
            filter = archive_write_add_filter_lz4(handle)
            options = "lz4:compression-level=9"
        case .zip: preconditionFailure("handled above")
        }
        // A warning here can mean an external helper is needed. Only linked-in
        // codecs are allowed; never open a writer that needs a subprocess.
        guard filter == ARCHIVE_OK else { return filter }
        return archive_write_set_options(handle, options)
    }
}

extension ZipCompression {
    fileprivate var options: String {
        switch self {
        case .balanced: "zip:compression=deflate,zip:compression-level=6"
        case .smallest: "zip:compression=deflate,zip:compression-level=9"
        case .store: "zip:compression=store"
        }
    }
}

extension ZipEncryption {
    fileprivate var options: String {
        switch self {
        case .aes256: "zip:encryption=aes256"
        case .zipCrypto: "zip:encryption=zipcrypt"
        }
    }
}

/// An archive written to a descriptor, one member at a time.
///
/// Member bytes stream in chunks. The codec additionally owns its compression
/// dictionary; maximum XZ/Zstd settings can require substantial memory.
///
/// The descriptor's life belongs to the caller — it came from the daemon and
/// this never closes it.
///
/// `@unchecked Sendable` for the same reason the reader is: it is handed to one
/// task at a time and never two, because the members go out in order and an
/// interleaved second writer would produce an archive rather than a race.
public final class ArchiveWriter: @unchecked Sendable {
    private let handle: OpaquePointer
    private var isFinished = false
    private let output: ArchiveOutput

    /// Set up before `self` exists, for the reason spelled out on
    /// `ArchiveReader.init`: one owner for the handle at every moment.
    ///
    /// A password encrypts every member of a zip with `encryption`; the tar
    /// formats have no encryption and a password is refused rather than
    /// silently dropped, because an archive the user believes is locked and
    /// is not is worse than no archive.
    public convenience init(
        descriptor: Int32,
        format: ArchiveFormat = .zip,
        zipCompression: ZipCompression = .balanced,
        encryption: ZipEncryption = .aes256,
        password: String? = nil
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FormatFailure.system(errno: errno) }
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        guard password == nil || format == .zip else {
            throw FormatFailure.unsupported("a password on a \(format.filenameExtension) archive")
        }
        guard let handle = archive_write_new() else { throw FormatFailure.system(errno: ENOMEM) }
        let output = ArchiveOutput(descriptor: descriptor)
        do {
            let configuration = format.configure(handle, zipCompression: zipCompression, encryption: password == nil ? nil : encryption)
            guard configuration == ARCHIVE_OK else {
                throw FormatFailure.damaged(archive_error_string(handle).map { String(cString: $0) } ?? "this archive format cannot be created")
            }
            try Self.check(handle, archive_write_set_bytes_in_last_block(handle, 1))
            if let password { try Self.check(handle, archive_write_set_passphrase(handle, password)) }
            try Self.check(handle, archive_write_open(handle, Unmanaged.passUnretained(output).toOpaque(), nil, { _, context, buffer, count in
                guard let context, let buffer else { return -1 }
                return Unmanaged<ArchiveOutput>.fromOpaque(context).takeUnretainedValue()
                    .write(buffer, count: count)
            }, nil), output: output)
        } catch {
            _ = withExtendedLifetime(output) { archive_write_free(handle) }
            throw error
        }
        self.init(handle: handle, output: output)
    }

    private init(handle: OpaquePointer, output: ArchiveOutput) {
        self.handle = handle
        self.output = output
    }

    deinit { _ = withExtendedLifetime(output) { archive_write_free(handle) } }

    public func addDirectory(_ path: String, mode: mode_t = 0o755, modified: Date = Date()) throws {
        try append(path, filetype: S_IFDIR, mode: mode, modified: modified, byteCount: 0, linkTarget: nil, progress: nil) { nil }
    }

    public func addSymbolicLink(
        _ path: String,
        target: String,
        mode: mode_t = 0o777,
        modified: Date = Date()
    ) throws {
        try append(path, filetype: S_IFLNK, mode: mode, modified: modified, byteCount: 0, linkTarget: target, progress: nil) { nil }
    }

    /// For content already in memory and known to be small — a symlink target,
    /// a `control` file. Anything on disk goes through `addFile`.
    public func addData(_ path: String, _ data: Data, mode: mode_t = 0o644, modified: Date = Date()) throws {
        var sent = false
        try append(path, filetype: S_IFREG, mode: mode, modified: modified, byteCount: Int64(data.count), linkTarget: nil, progress: nil) {
            defer { sent = true }
            return sent ? nil : data
        }
    }

    /// Streams a file straight from its descriptor. Mode and modification time
    /// come from the file unless the caller overrides them — an archive that
    /// loses the executable bit unpacks into a binary nobody can run.
    public func addFile(
        _ path: String,
        from source: Int32,
        mode: mode_t? = nil,
        modified: Date? = nil,
        progress: ProgressHandler? = nil
    ) throws {
        var status = stat()
        guard fstat(source, &status) == 0 else { throw FormatFailure.system(errno: errno) }
        let reader = try DescriptorReader(descriptor: source)
        var offset: Int64 = 0

        try append(
            path,
            filetype: S_IFREG,
            mode: mode ?? status.st_mode,
            modified: modified ?? Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)),
            byteCount: reader.byteCount,
            linkTarget: nil,
            progress: progress
        ) {
            guard offset < reader.byteCount else { return nil }
            let chunk = try reader.readUpTo(at: offset, count: chunkByteCount)
            offset += Int64(chunk.count)
            return chunk.isEmpty ? nil : chunk
        }
    }

    /// Writes the trailer. An archive that is never finished is not one — a
    /// zip's central directory is the only listing a reader has.
    public func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        try Self.check(handle, archive_write_close(handle), output: output)
    }

    private func append(
        _ declared: String,
        filetype: mode_t,
        mode: mode_t,
        modified: Date,
        byteCount: Int64,
        linkTarget: String?,
        progress: ProgressHandler?,
        chunks: () throws -> Data?
    ) throws {
        guard !isFinished else { throw FormatFailure.damaged("the archive is already finished") }
        // The names this writer is handed are the app's own — a tree walk over
        // paths the daemon returned — so a `..` in one is a bug here rather than
        // an attack. It still refuses: an archive Fila wrote that attacks
        // whoever opens it next would be this app's fault either way.
        guard let path = ArchivePath.validated(declared) else {
            throw FormatFailure.damaged("“\(declared)” is not a name an archive may carry")
        }

        guard let entry = archive_entry_new() else { throw FormatFailure.system(errno: ENOMEM) }
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname_utf8(entry, path)
        // libarchive's `AE_IFREG` and friends are the `S_IF*` values with a cast
        // the Swift importer drops, and they are defined to be interchangeable.
        // Using the POSIX names keeps this file speaking the same vocabulary as
        // `FileKind(modeBits:)` on the reading side.
        archive_entry_set_filetype(entry, UInt32(filetype))
        archive_entry_set_perm(entry, mode & 0o7777)
        archive_entry_set_mtime(entry, Self.unixTime(modified), 0)
        if let linkTarget { archive_entry_set_symlink_utf8(entry, linkTarget) }
        // A tar needs the length in the header it writes before the payload, so
        // this is not optional even for the formats that could stream.
        archive_entry_set_size(entry, filetype == S_IFREG ? byteCount : 0)

        try Self.check(handle, archive_write_header(handle, entry), output: output)

        var written: Int64 = 0
        while let chunk = try chunks() {
            try chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let put = archive_write_data(handle, base.advanced(by: sent), raw.count - sent)
                    guard put > 0 else { throw output.failure.map { FormatFailure.system(errno: $0) } ?? archiveFailure(handle) }
                    sent += put
                }
            }
            written += Int64(chunk.count)
            try checkCancellation(progress, written, byteCount)
        }

        // The header already promised a length, and the format gives no way to
        // take that back once it is written — so a file that shrank between the
        // `fstat` and the last read takes the whole archive down with it.
        //
        // That is deliberate and it is the expensive choice: compressing a
        // directory while something inside it rotates a log loses the archive
        // rather than one member. The alternative is padding the shortfall with
        // zeroes, which produces an archive that opens, extracts, and hands the
        // user a file that is not what was on disk. A failure the user can see
        // beats a corruption they cannot.
        guard filetype != S_IFREG || written == byteCount else {
            throw FormatFailure.damaged("“\(path)” changed size while it was being archived")
        }
        try Self.check(handle, archive_write_finish_entry(handle), output: output)
    }

    /// Seconds since 1970, clamped rather than trapped.
    ///
    /// `time_t(someDouble)` traps on a value outside `time_t`, and this one came
    /// off a filesystem people edit as root: a file whose `st_mtime` is nonsense
    /// is a thing that exists, and it must not take the archiver down with it.
    private static func unixTime(_ date: Date) -> time_t {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        if seconds >= Double(time_t.max) { return .max }
        if seconds <= Double(time_t.min) { return .min }
        return time_t(seconds)
    }

    private static func check(_ handle: OpaquePointer, _ status: Int32, output: ArchiveOutput? = nil) throws {
        if let failure = output?.failure { throw FormatFailure.system(errno: failure) }
        guard status != ARCHIVE_OK, status != ARCHIVE_WARN else { return }
        throw archiveFailure(handle)
    }
}

/// libarchive also writes headers and trailers, so the output callback owns the
/// space check. The caller continues to own the descriptor.
private final class ArchiveOutput {
    let descriptor: Int32
    private(set) var failure: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return -1 }
        do {
            try StorageSpace.requireAvailable(Int64(count), descriptor: descriptor)
            var written = 0
            while written < count {
                let result = Darwin.write(descriptor, buffer.advanced(by: written), count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw FilaFailure(errno: result == 0 ? ENOSPC : errno) }
                written += result
            }
            return written
        } catch {
            failure = (error as? FilaFailure)?.systemError ?? EIO
            return -1
        }
    }
}
