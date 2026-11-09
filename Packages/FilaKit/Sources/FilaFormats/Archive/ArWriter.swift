import Darwin
import Foundation

/// Writes the `ar` container a `.deb` is made of: the magic `!<arch>\n`, then
/// for every member a 60-byte header and the member's bytes, padded to an even
/// length with `\n`.
///
/// Nothing here looks inside a member. `debian-binary` is copied from four
/// bytes of memory and `control.tar.*` and `data.tar.*` are copied from the
/// descriptor they came from, so a package is assembled without a byte of a
/// member being decompressed, interpreted or held in memory, and without
/// spawning `dpkg-deb` — the app has no business running a program to write a
/// file it can write itself.
///
/// The layout is Debian's, not GNU `ar`'s: member names are written plain and
/// space-padded rather than `/`-terminated, which is what `dpkg-deb` writes and
/// what every dpkg on a device reads back.
public final class ArWriter: @unchecked Sendable {
    private let descriptor: Int32
    private var written: Set<String> = []
    private static let copyChunk = 1 << 20

    /// Fails early on something that is not a regular file: a partial archive
    /// written into a directory descriptor would be discovered only by the
    /// package manager.
    public init(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw FormatFailure.system(errno: Darwin.errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw FormatFailure.unsupported("an ar archive needs a regular file to write into")
        }
        self.descriptor = descriptor
        try Self.write(Array("!<arch>\n".utf8), to: descriptor)
    }

    /// A member already in memory. `debian-binary` is the only one: anything
    /// else can be megabytes and goes through `addMember(name:source:)`.
    public func addMember(
        name: String,
        data: Data,
        modified: Date = Date(),
        mode: mode_t = 0o100644,
    ) throws {
        try addMember(name: name, byteCount: Int64(data.count), modified: modified, mode: mode) { buffer, offset, count in
            let start = Int(offset)
            guard start < data.count else { return 0 }
            let length = min(count, data.count - start)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.copyMemory(from: base.advanced(by: start), byteCount: length)
            }
            return length
        }
    }

    /// Copies `byteCount` bytes from `source`, which stays open and untouched
    /// at whatever offset the caller left it: reads are positional, so a
    /// descriptor the caller still needs reads the same before and after.
    public func addMember(
        name: String,
        source: Int32,
        byteCount: Int64,
        modified: Date = Date(),
        mode: mode_t = 0o100644,
    ) throws {
        try addMember(name: name, byteCount: byteCount, modified: modified, mode: mode) { buffer, offset, count in
            while true {
                let read = pread(source, buffer, count, off_t(offset))
                if read >= 0 { return read }
                guard Darwin.errno == EINTR else { throw FormatFailure.system(errno: Darwin.errno) }
            }
        }
    }

    /// The one path every member goes through, so the header, the bytes and
    /// the padding are never written by two different rules.
    ///
    /// `next` fills up to `count` bytes at `offset` and answers how many it
    /// wrote; zero means the source ended early, which is a failed member
    /// rather than a short one — a package whose `data.tar` is 40 bytes shorter
    /// than its header says is refused by dpkg long after the file left the
    /// device.
    private func addMember(
        name: String,
        byteCount: Int64,
        modified: Date,
        mode: mode_t,
        next: (UnsafeMutableRawPointer, Int64, Int) throws -> Int,
    ) throws {
        guard byteCount >= 0 else { throw FormatFailure.unsupported("a negative member length") }
        try Self.write(try header(name: name, size: byteCount, modified: modified, mode: mode), to: descriptor)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.copyChunk, alignment: 16)
        defer { buffer.deallocate() }
        var offset: Int64 = 0
        while offset < byteCount {
            let wanted = Int(min(Int64(Self.copyChunk), byteCount - offset))
            let count = try next(buffer, offset, wanted)
            guard count > 0, count <= wanted else {
                throw FormatFailure.damaged("\(name) ended \(byteCount - offset) bytes before its stated length")
            }
            try Self.write(UnsafeRawBufferPointer(start: buffer, count: count), to: descriptor)
            offset += Int64(count)
        }
        // Every member starts on an even byte: the format pads with `\n`, not
        // with zeros, and a reader that trusts the header walks one byte wrong
        // if it is missing.
        if byteCount % 2 == 1 {
            try Self.write([0x0A], to: descriptor)
        }
    }

    private func header(name: String, size: Int64, modified: Date, mode: mode_t) throws -> [UInt8] {
        guard !name.isEmpty, name.utf8.count <= 16 else {
            throw FormatFailure.unsupported("an ar member name longer than 16 bytes")
        }
        guard written.insert(name).inserted else {
            throw FormatFailure.unsupported("two members named \(name)")
        }
        func field(_ text: String, width: Int) throws -> [UInt8] {
            var bytes = Array(text.utf8)
            guard bytes.count <= width else {
                throw FormatFailure.unsupported("an ar field wider than \(width) bytes")
            }
            bytes.append(contentsOf: repeatElement(0x20, count: width - bytes.count))
            return bytes
        }
        var header = try field(name, width: 16)
        header += try field(String(Int64(modified.timeIntervalSince1970)), width: 12)
        header += try field("0", width: 6) // uid
        header += try field("0", width: 6) // gid
        header += try field(String(mode, radix: 8), width: 8)
        header += try field(String(size), width: 10)
        header += Array("`\n".utf8)
        return header
    }

    /// A short write is the normal case on a descriptor the daemon opened, and
    /// `EINTR` is normal on a device that delivers signals. Both loop here so
    /// no caller has to.
    private static func write(_ bytes: [UInt8], to descriptor: Int32) throws {
        try bytes.withUnsafeBufferPointer { buffer in
            try write(UnsafeRawBufferPointer(buffer), to: descriptor)
        }
    }

    private static func write(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var start = 0
        while start < bytes.count {
            let count = Darwin.write(descriptor, base + start, bytes.count - start)
            if count > 0 {
                start += count
                continue
            }
            if count < 0, Darwin.errno == EINTR { continue }
            throw FormatFailure.system(errno: count < 0 ? Darwin.errno : ENOSPC)
        }
    }
}
