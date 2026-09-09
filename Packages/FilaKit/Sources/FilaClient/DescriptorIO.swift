import FilaFileOps
import FilaProtocol
import Foundation

/// Blocking descriptor reads, kept out of the actor that owns the link so a
/// gigabyte file cannot stall the main thread.
public enum DescriptorIO {
    public static let chunkByteCount = 256 * 1024

    /// Reads up to `limit` bytes and **closes** the descriptor. Every descriptor
    /// the daemon passes back is a real one in this process; leaking them is how
    /// a browsing session runs the app out of them.
    public static func readAndClose(_ descriptor: Int32, limit: Int) throws -> Data {
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FilaFailure(errno: errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0, limit >= 0 else {
            throw FilaFailure(errno: EINVAL)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        while data.count < limit {
            let want = min(buffer.count, limit - data.count)
            let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, want) }
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw FilaFailure(errno: errno)
            }
            if got == 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< got])
        }
        return data
    }

    public static func copyAndClose(_ descriptor: Int32, to url: URL) throws {
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw FilaFailure(errno: errno) }
        guard original.st_mode & S_IFMT == S_IFREG, original.st_size >= 0 else {
            throw FilaFailure(errno: EINVAL)
        }
        try StorageSpace.requireAvailable(Int64(original.st_size), at: url.deletingLastPathComponent().path)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FilaFailure(code: .operationFailed, systemError: EIO, path: url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        var remaining = original.st_size
        while remaining > 0 {
            let count = Int(min(remaining, off_t(buffer.count)))
            let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, count) }
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw FilaFailure(code: .operationFailed, systemError: errno, path: url.path)
            }
            guard got != 0 else { throw FilaFailure(errno: EIO, path: url.path) }
            try StorageSpace.requireAvailable(Int64(got), descriptor: handle.fileDescriptor)
            try handle.write(contentsOf: Data(buffer[0 ..< got]))
            remaining -= off_t(got)
        }
        var current = stat()
        guard fstat(descriptor, &current) == 0 else { throw FilaFailure(errno: errno) }
        guard current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        else {
            throw FilaFailure(errno: EBUSY, path: url.path)
        }
        try handle.synchronize()
    }
}

extension DescriptorIO {
    /// Streams a file from the app's container into a descriptor `filad` opened,
    /// and **closes** it. The reverse of copying a descriptor to a URL, and chunked for the same
    /// reason: a download is as large as the user's connection allows.
    public static func copyAndClose(_ descriptor: Int32, from url: URL) throws {
        defer { close(descriptor) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: chunkByteCount) ?? Data()
            if chunk.isEmpty {
                while fsync(descriptor) != 0 {
                    if errno != EINTR {
                        throw FilaFailure(errno: errno, path: url.path)
                    }
                }
                return
            }
            try StorageSpace.requireAvailable(Int64(chunk.count), descriptor: descriptor)
            try chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let put = write(descriptor, base + written, raw.count - written)
                    if put < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw FilaFailure(code: .operationFailed, systemError: errno, path: url.path)
                    }
                    if put == 0 {
                        throw FilaFailure(code: .operationFailed, systemError: ENOSPC, path: url.path)
                    }
                    written += put
                }
            }
        }
    }
}
