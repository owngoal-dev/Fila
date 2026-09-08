import Darwin
import FilaProtocol
import Foundation

/// Keep a reserve on the volume receiving a write. This is a live check, not
/// a reservation: concurrent writers can still consume space after statfs.
public enum StorageSpace {
    public static let reserveByteCount: Int64 = 256 * 1_024 * 1_024

    public static func requireAvailable(_ byteCount: Int64 = 0, descriptor: Int32) throws {
        var status = statfs()
        guard fstatfs(descriptor, &status) == 0 else { throw FilaFailure(errno: errno) }
        try validate(availableByteCount: available(status), writing: byteCount)
    }

    public static func requireAvailable(_ byteCount: Int64 = 0, at path: String) throws {
        let path = try FilaPath.canonical(path)
        var status = statfs()
        guard statfs(path, &status) == 0 else { throw FilaFailure(errno: errno, path: path) }
        try validate(availableByteCount: available(status), writing: byteCount)
    }

    static func validate(availableByteCount: Int64, writing byteCount: Int64) throws {
        guard byteCount >= 0 else { throw FilaFailure(errno: EINVAL) }
        guard availableByteCount >= reserveByteCount, byteCount <= availableByteCount - reserveByteCount else {
            throw FilaFailure(errno: ENOSPC)
        }
    }

    private static func available(_ status: statfs) -> Int64 {
        let (bytes, overflow) = UInt64(status.f_bavail).multipliedReportingOverflow(by: UInt64(status.f_bsize))
        return overflow ? .max : Int64(clamping: bytes)
    }
}
