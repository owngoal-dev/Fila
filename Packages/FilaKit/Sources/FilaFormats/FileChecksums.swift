import CryptoKit
import Darwin
import Foundation

/// One bounded pass over a borrowed regular-file descriptor. The caller closes it.
public struct FileChecksums: Sendable {
    public let md5: String
    public let sha1: String
    public let sha256: String

    public static func read(descriptor: Int32) throws -> Self {
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard original.st_mode & S_IFMT == S_IFREG, original.st_size >= 0 else { throw POSIXError(.EINVAL) }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var offset: off_t = 0
        while offset < original.st_size {
            try Task.checkCancellation()
            let wanted = Int(min(off_t(buffer.count), original.st_size - offset))
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, offset) }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw POSIXError(.EBUSY) }
            buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(rebasing: bytes[..<count])
                md5.update(bufferPointer: chunk)
                sha1.update(bufferPointer: chunk)
                sha256.update(bufferPointer: chunk)
            }
            offset += off_t(count)
        }
        try Task.checkCancellation()
        var current = stat()
        guard fstat(descriptor, &current) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw POSIXError(.EBUSY) }
        func hex<D: Digest>(_ digest: D) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        return Self(md5: hex(md5.finalize()), sha1: hex(sha1.finalize()), sha256: hex(sha256.finalize()))
    }
}
