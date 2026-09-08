import FilaFileOps
import FilaProtocol
import Foundation
import LibArchive

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

public enum ArchivePath {
    /// Finder's layout database and ZIP metadata directory are not user files.
    /// Other dotfiles, including ordinary names starting with `._`, stay intact.
    public static func isFinderMetadata(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.last == ".DS_Store" || components.contains("__MACOSX")
    }

    /// Remove the compound tar suffix as one format, preserving dots in names.
    public static func extractionFolderName(for name: String) -> String {
        let file = (name as NSString).lastPathComponent
        let suffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.zstd", ".tar.lzma", ".tar.lz4", ".tar.lz", ".tar.Z",
        ]
        if let suffix = suffixes.first(where: { file.lowercased().hasSuffix($0.lowercased()) }) {
            return String(file.dropLast(suffix.count))
        }
        return (file as NSString).deletingPathExtension
    }

    /// The one form of an entry name that may be appended to a destination.
    ///
    /// Checked by walking components, never by normalising the string:
    /// `FilaGuard.normalize` collapses a leading `..` against the root the way
    /// the kernel does, which is right for an absolute path and exactly wrong
    /// here — it would turn an escape into a legal-looking relative one.
    public static func validated(_ declared: String) -> String? {
        guard !declared.isEmpty, !declared.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in declared.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": return nil
            default: components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}

/// An archive read through a descriptor `filad` opened as root.
///
/// libarchive is forward-only: `next()` walks to the following header, and the
/// current entry's bytes are streamed with `read` before the next call moves
/// past them. Listing an archive and then extracting part of it is therefore
/// two passes over the same file, which is why this takes a descriptor rather
/// than owning one — the caller opens a fresh one per pass and closes it.
///
/// **Nothing here writes to a filesystem.** `archive_read_extract` and the
/// `archive_write_disk` family exist and are deliberately not used: they would
/// create files with this process's own credentials, which would both bypass
/// `filad` and bypass `FilaGuard`. Every byte leaves through a descriptor the
/// caller obtained one path at a time, and every path it obtained went past the
/// daemon's guard on the way.
///
/// Memory is flat: `archive_read_data_block` hands back libarchive's own buffer
/// and it goes straight to the sink, so a 4 GB member costs the 64 KB read
/// buffer and nothing else.
///
/// `@unchecked Sendable` because it is handed to one task at a time and never
/// two — the handle carries a file position and interleaving two readers of it
/// would produce garbage rather than a race the compiler can see.
public final class ArchiveReader: @unchecked Sendable {
    /// An archive claiming more members than this is one whose header count is
    /// being used to hang the app; no real archive on a phone is near it.
    ///
    /// Public because `list` stopping here is not something to hide: a caller
    /// that gets exactly this many entries back has a listing that may be
    /// incomplete, and the user is entitled to be told.
    public static let maximumEntryCount = 50000
    public static let maximumListingByteCount = 16 * 1024 * 1024

    private let handle: OpaquePointer
    private let source: ArchiveSource
    /// The name of the file the descriptor belongs to, used only to name the
    /// single member of a lone gzip or xz — those formats record a payload with
    /// no name of its own.
    private let sourceName: String?
    private var current: OpaquePointer?
    private var isFinished = false
    private var hasInspectedFormat = false

    /// Everything that can fail happens before `self` exists, so the handle has
    /// exactly one owner at every moment: this function until `self.init`, and
    /// `deinit` afterwards. Doing the setup inside a throwing initialiser
    /// instead would leave the free to a subtlety — Swift runs `deinit` for a
    /// throwing initialiser that had already set every stored property — and a
    /// handle freed twice is not a subtlety worth living with.
    public convenience init(descriptor: Int32, name: String? = nil, password: String? = nil) throws {
        let source = try ArchiveSource(descriptor: descriptor)
        guard let handle = archive_read_new() else { throw FormatFailure.system(errno: ENOMEM) }
        if let password, !password.isEmpty {
            archive_read_add_passphrase(handle, password)
        }

        archive_read_support_filter_all(handle)
        archive_read_support_format_all(handle)
        // Not part of `format_all`, and it must be added after it: raw bids
        // lowest, so a real format always wins and this only catches what is
        // left — a `.gz` or `.xz` wrapped straight around a file rather than
        // around a tar.
        archive_read_support_format_raw(handle)

        archive_read_set_callback_data(handle, Unmanaged.passUnretained(source).toOpaque())
        archive_read_set_read_callback(handle) { _, clientData, buffer in
            guard let clientData, let buffer else { return -1 }
            return Unmanaged<ArchiveSource>.fromOpaque(clientData).takeUnretainedValue().fill(buffer)
        }
        archive_read_set_seek_callback(handle) { _, clientData, offset, whence in
            guard let clientData else { return Int64(ARCHIVE_FATAL) }
            return Unmanaged<ArchiveSource>.fromOpaque(clientData).takeUnretainedValue()
                .seek(to: offset, whence: whence)
        }
        archive_read_set_skip_callback(handle) { _, clientData, request in
            guard let clientData else { return 0 }
            return Unmanaged<ArchiveSource>.fromOpaque(clientData).takeUnretainedValue().skip(request)
        }

        do {
            guard try withArchiveLocale({ archive_read_open1(handle) }) == ARCHIVE_OK else {
                throw archiveFailure(handle)
            }
        } catch {
            archive_read_free(handle)
            throw error
        }
        self.init(handle: handle, source: source, name: name)
    }

    private init(handle: OpaquePointer, source: ArchiveSource, name: String?) {
        self.handle = handle
        self.source = source
        sourceName = name
    }

    deinit { archive_read_free(handle) }

    /// The next header, or nil at the end of the archive. Any bytes left in the
    /// current entry are skipped.
    public func next() throws -> ArchiveEntry? {
        try withArchiveLocale {
            guard !isFinished else { return nil }
            var entry: OpaquePointer?
            let status = archive_read_next_header(handle, &entry)
            if status == ARCHIVE_EOF {
                isFinished = true
                current = nil
                return nil
            }
            try check(status)
            guard let entry else {
                isFinished = true
                return nil
            }
            try refuseABareRawMember()
            current = entry
            return makeEntry(entry)
        }
    }

    /// The price of `support_format_raw`: it bids on *anything*, so with it
    /// enabled every file is an archive of one nameless member — a plist the
    /// browser was sent to by a wrong guess included.
    ///
    /// Raw is only meaningful when a compression filter produced the bytes: a
    /// lone `.gz` or `.xz` around something that is not a tar. With no filter in
    /// the chain — `archive_filter_count` is 1 for a plain file and 2 or more
    /// once something decompressed it — a raw member is just a file, and saying
    /// so is what lets the caller fall back to another viewer.
    private func refuseABareRawMember() throws {
        guard !hasInspectedFormat else { return }
        hasInspectedFormat = true
        guard archive_format(handle) == ARCHIVE_FORMAT_RAW, archive_filter_count(handle) <= 1 else { return }
        isFinished = true
        current = nil
        throw FormatFailure.notRecognised
    }

    /// Streams the current entry's bytes into `sink`, a block at a time.
    ///
    /// The sink is handed the offset as well as the bytes because
    /// `archive_read_data_block` is allowed to skip: a sparse member reports the
    /// holes by jumping the offset rather than by handing over zeroes, and a
    /// sink that appends would compact the file into something shorter than the
    /// archive says it is.
    ///
    /// The buffer belongs to libarchive and is valid only for the call — copy
    /// anything kept.
    public func read(
        progress: ProgressHandler? = nil,
        into sink: (_ offset: Int64, _ bytes: UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard current != nil else { throw FormatFailure.damaged("its contents could not be read") }
        let total = currentByteCount ?? 0
        var done: Int64 = 0

        while true {
            var buffer: UnsafeRawPointer?
            var count = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(handle, &buffer, &count, &offset)
            if status == ARCHIVE_EOF {
                break
            }
            // Strict here, unlike the header walk, which tolerates a warning.
            // A warning on the *data* path means libarchive handed over bytes it
            // is not happy with, and silently extracting corruption is worse
            // than not extracting. (libarchive 3.8.9 reports a zip CRC mismatch
            // as fatal, so this is belt to that braces — but the cost of being
            // wrong in the other direction is a file the user cannot tell is
            // damaged.)
            guard status == ARCHIVE_OK else { throw archiveFailure(handle) }
            if let buffer, count > 0 {
                try sink(offset, UnsafeRawBufferPointer(start: buffer, count: count))
                done += Int64(count)
            }
            // libarchive's own loop is synchronous from here to the end of the
            // member, so this is the only place a cancel can be noticed.
            try checkCancellation(progress, done, total)
        }
    }

    /// Streams the current entry into a descriptor the caller opened for
    /// writing — in the app, that is one `filad` handed back for a single path
    /// it had already checked.
    @discardableResult
    public func read(
        into destination: Int32,
        maximumByteCount: Int64 = .max,
        progress: ProgressHandler? = nil
    ) throws -> Int64 {
        if let size = currentByteCount, size > maximumByteCount {
            throw FormatFailure.tooLarge(byteCount: size, limit: maximumByteCount)
        }
        try StorageSpace.requireAvailable(descriptor: destination)
        var end: Int64 = 0
        try read(progress: progress) { offset, bytes in
            guard offset >= 0, offset <= maximumByteCount, Int64(bytes.count) <= maximumByteCount - offset else {
                throw FormatFailure.tooLarge(byteCount: .max, limit: maximumByteCount)
            }
            // Header sizes are untrusted estimates. Keep checking actual output
            // even when the UI's preflight says the archive will fit.
            try StorageSpace.requireAvailable(Int64(bytes.count), descriptor: destination)
            try writeFully(bytes, to: destination, at: offset)
            end = max(end, offset + Int64(bytes.count))
        }
        // Only reached once the loop above saw a clean end-of-member: a short or
        // corrupt one throws rather than arriving here, so a shortfall at this
        // point is a sparse member whose last block is a hole, and the archive's
        // own size is the truth about how long the file should be.
        if let size = currentByteCount, size > end {
            guard ftruncate(destination, off_t(size)) == 0 else { throw FormatFailure.system(errno: errno) }
            end = size
        }
        return end
    }

    /// The whole of the current entry in memory.
    ///
    /// For a symlink target, a `control` file, an `Info.plist` — things measured
    /// in kilobytes. The limit is checked against the header where the archive
    /// records one and against the bytes as they arrive where it does not, which
    /// is what makes a lone gzip safe to open without a ceiling on the file
    /// itself.
    public func data(maximumByteCount: Int64 = 16 * 1024 * 1024) throws -> Data {
        if let size = currentByteCount, size > maximumByteCount {
            throw FormatFailure.tooLarge(byteCount: size, limit: maximumByteCount)
        }
        var data = Data()
        if let size = currentByteCount {
            data.reserveCapacity(Int(size))
        }
        try read { offset, bytes in
            guard offset >= 0, offset <= maximumByteCount, Int64(bytes.count) <= maximumByteCount - offset else {
                throw FormatFailure.tooLarge(byteCount: .max, limit: maximumByteCount)
            }
            let end = Int(offset) + bytes.count
            if end > data.count {
                data.append(Data(count: end - data.count))
            }
            data.replaceSubrange(Int(offset) ..< end, with: bytes)
        }
        return data
    }

    /// Every header in one pass, which is what a browser shows.
    ///
    /// Nothing is extracted: for a zip libarchive reads the central directory,
    /// and for a stream format it walks the headers past the payloads. A
    /// compressed tar still has to be decompressed to be walked — that is the
    /// format, not a choice here.
    public static func list(
        descriptor: Int32,
        name: String? = nil,
        progress: ProgressHandler? = nil
    ) throws -> [ArchiveEntry] {
        let reader = try ArchiveReader(descriptor: descriptor, name: name)
        var entries: [ArchiveEntry] = []
        var remainingBytes = maximumListingByteCount
        while entries.count < maximumEntryCount, let entry = try reader.next() {
            let bytes = entry.declaredPath.utf8.count
                + (entry.linkTarget?.utf8.count ?? 0)
                + (entry.hardLinkTarget?.utf8.count ?? 0)
            guard bytes <= remainingBytes else {
                throw FormatFailure.tooLarge(
                    byteCount: Int64(maximumListingByteCount) + 1,
                    limit: Int64(maximumListingByteCount)
                )
            }
            remainingBytes -= bytes
            entries.append(entry)
            try checkCancellation(progress, Int64(entries.count), 0)
        }
        return entries
    }

    // MARK: - Headers

    /// The size the current entry's header claims, or nil when it claims none.
    ///
    /// A negative one counts as none: the number came out of a file this app did
    /// not write, and it reaches `reserveCapacity` and `ftruncate` below.
    private var currentByteCount: Int64? {
        guard let current, archive_entry_size_is_set(current) != 0 else { return nil }
        let size = archive_entry_size(current)
        return size >= 0 ? size : nil
    }

    private func makeEntry(_ entry: OpaquePointer) -> ArchiveEntry {
        // The raw format has no header at all: one nameless member, no type and
        // no size. It is a lone `.gz` or `.xz` around something that is not a
        // tar, and the honest name for it is the file's own with the
        // compression suffix taken off.
        let isRaw = archive_format(handle) == ARCHIVE_FORMAT_RAW
        let declared = isRaw
            ? Self.strippingCompressionSuffix(sourceName ?? Self.string(archive_entry_pathname(entry)) ?? "data")
            : (Self.pathname(entry) ?? "")

        var kind = isRaw ? .regular : FileKind(modeBits: mode_t(archive_entry_filetype(entry)))
        // A format that records no type at all leaves one signal: zip marks a
        // directory by the trailing slash and nothing else.
        if kind == .unknown {
            kind = declared.hasSuffix("/") ? .directory : .regular
        }

        // A zip written on Windows carries no Unix permissions. Extracting its
        // members as mode 0 makes files nobody can open, so a plausible default
        // stands in — at the cost of not reproducing a deliberate `chmod 000`,
        // which is the rarer of the two by a wide margin.
        var permissions = mode_t(archive_entry_perm(entry)) & 0o7777
        if permissions == 0 {
            permissions = kind == .directory ? 0o755 : 0o644
        }

        return ArchiveEntry(
            declaredPath: declared,
            kind: kind,
            byteCount: currentByteCount,
            mode: Self.typeBits(kind) | permissions,
            modified: archive_entry_mtime_is_set(entry) != 0
                ? Date(timeIntervalSince1970: Double(archive_entry_mtime(entry)))
                : nil,
            linkTarget: Self.string(archive_entry_symlink_utf8(entry)) ?? Self.string(archive_entry_symlink(entry)),
            hardLinkTarget: Self.string(archive_entry_hardlink_utf8(entry))
                ?? Self.string(archive_entry_hardlink(entry)),
            isEncrypted: archive_entry_is_data_encrypted(entry) != 0
        )
    }

    private static func typeBits(_ kind: FileKind) -> mode_t {
        switch kind {
        case .directory: S_IFDIR
        case .symbolicLink: S_IFLNK
        case .fifo: S_IFIFO
        case .socket: S_IFSOCK
        case .blockDevice: S_IFBLK
        case .characterDevice: S_IFCHR
        case .regular, .unknown: S_IFREG
        }
    }

    /// The entry's name, preferring libarchive's own UTF-8 conversion.
    ///
    /// `archive_entry_pathname_utf8` returns nil when the archive's declared
    /// charset cannot be converted, and the raw bytes are then decoded with
    /// U+FFFD substituted for what is not UTF-8. Such an entry still extracts,
    /// under the substituted name: the replacement only ever touches bytes above
    /// 0x7F, so it cannot manufacture a `/` or a `..`, and refusing a whole
    /// archive because one member was named in Shift-JIS helps nobody.
    private static func pathname(_ entry: OpaquePointer) -> String? {
        if let utf8 = string(archive_entry_pathname_utf8(entry)) {
            return utf8
        }
        guard let raw = archive_entry_pathname(entry) else { return nil }
        return String(decoding: Data(bytes: raw, count: strlen(raw)), as: UTF8.self)
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(validatingUTF8: pointer)
    }

    private static func strippingCompressionSuffix(_ name: String) -> String {
        let lowered = name.lowercased()
        for suffix in [".gz", ".bz2", ".xz", ".lzma", ".zst", ".lz4", ".Z"]
            where lowered.hasSuffix(suffix.lowercased())
        {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: - Failures

    private func check(_ status: Int32) throws {
        // ARCHIVE_WARN is a member libarchive read anyway — an unsupported
        // extended attribute, a timestamp it could not convert. Failing on it
        // would refuse archives every other tool opens.
        guard status != ARCHIVE_OK, status != ARCHIVE_WARN else { return }
        throw archiveFailure(handle)
    }
}

/// libarchive's own message, carried through rather than flattened into
/// something this module made up. *Truncated ZIP file data* and *Unsupported ZIP
/// compression method (Deflate64)* are different problems and only one of them
/// means the file is broken, which is the whole of the sorting done here.
///
/// `.notRecognised` is deliberately not produced here. libarchive decides which
/// format an archive is inside `archive_read_next_header`, not at open, and with
/// `support_format_raw` enabled *something* always bids — so "this is not an
/// archive" has exactly one owner, `refuseABareRawMember`, and it is not this.
func archiveFailure(_ handle: OpaquePointer) -> FormatFailure {
    let code = archive_errno(handle)
    if code == ENOSPC {
        return .system(errno: code)
    }
    guard let raw = archive_error_string(handle), let message = String(validatingUTF8: raw) else {
        return .system(errno: code == 0 ? EIO : code)
    }
    // The only signal the library gives for "the file is fine, I just cannot do
    // this one" is that those messages start *Unsupported* or *Unrecognized*. If
    // the wording ever changes the user gets the damaged sentence with the true
    // reason still attached, which is a soft landing.
    if message.hasPrefix("Unsupported") || message.hasPrefix("Unrecogni") {
        return .unsupported(message)
    }
    // "Passphrase required for this entry" and "Incorrect passphrase" are the
    // two ways the zip reader says it, and both have the same way out.
    if message.localizedCaseInsensitiveContains("passphrase") {
        return .wrongPassword
    }
    return .damaged(message)
}

/// libarchive reading through `pread(2)`, so the descriptor's own file offset is
/// never moved.
///
/// `archive_read_open_fd` would use `read(2)` and `lseek(2)`. The descriptor
/// arrived over XPC and this process does not know what else holds a reference
/// to the same open file description; moving the shared offset would corrupt
/// whoever else is reading it. It is also what lets two passes over one archive
/// start from zero without reopening anything.
private final class ArchiveSource {
    private let descriptor: Int32
    private let byteCount: Int64
    private let buffer: UnsafeMutableRawPointer
    private var offset: Int64 = 0

    init(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FormatFailure.system(errno: errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw FormatFailure.system(errno: EINVAL) }
        self.descriptor = descriptor
        byteCount = Int64(status.st_size)
        buffer = .allocate(byteCount: chunkByteCount, alignment: MemoryLayout<UInt64>.alignment)
    }

    deinit { buffer.deallocate() }

    /// Points libarchive at the next block. Zero is end of file; negative is a
    /// fatal read error, which libarchive turns into its own message.
    func fill(_ destination: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        while true {
            let got = pread(descriptor, buffer, chunkByteCount, off_t(offset))
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                return -1
            }
            destination.pointee = UnsafeRawPointer(buffer)
            offset += Int64(got)
            return got
        }
    }

    /// Every offset below comes out of a header this app did not write, so the
    /// arithmetic reports its overflow instead of trapping on it: a length field
    /// near `Int64.max` is a plausible thing to find in a hostile archive, and
    /// `+` on one takes the app down.
    func seek(to target: Int64, whence: Int32) -> Int64 {
        let base: Int64
        switch whence {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = offset
        case SEEK_END: base = byteCount
        default: return Int64(ARCHIVE_FATAL)
        }
        let (destination, overflowed) = base.addingReportingOverflow(target)
        guard !overflowed, destination >= 0 else { return Int64(ARCHIVE_FATAL) }
        offset = destination
        return offset
    }

    /// Skipping past the end is not an error — libarchive asks for it at the end
    /// of a truncated member — but the answer has to be how far this actually
    /// went, which is what libarchive uses to decide the member was short.
    func skip(_ request: Int64) -> Int64 {
        guard request > 0 else { return 0 }
        let skipped = min(request, max(0, byteCount - offset))
        offset += skipped
        return skipped
    }
}
