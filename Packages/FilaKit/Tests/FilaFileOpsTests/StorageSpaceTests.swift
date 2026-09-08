import Darwin
import Foundation
import Testing
@testable import FilaFileOps
import FilaProtocol

struct StorageSpaceTests {
    @Test("Writes preserve the reserve at the exact boundary")
    func boundaries() throws {
        let reserve = StorageSpace.reserveByteCount
        try StorageSpace.validate(availableByteCount: reserve + 17, writing: 17)
        #expect(throws: FilaFailure(errno: ENOSPC)) {
            try StorageSpace.validate(availableByteCount: reserve + 16, writing: 17)
        }
        #expect(throws: FilaFailure(errno: ENOSPC)) {
            try StorageSpace.validate(availableByteCount: reserve - 1, writing: 0)
        }
        #expect(throws: FilaFailure(errno: EINVAL)) {
            try StorageSpace.validate(availableByteCount: .max, writing: -1)
        }
    }

    @Test("Read descriptors are nonblocking and still return ordinary file bytes")
    func nonblockingRead() throws {
        let scratch = Scratch()
        let path = scratch.file("ordinary.txt")
        let descriptor = try FileOperations(bootstrapRoot: "").open(path, flags: O_RDONLY, mode: 0)
        defer { close(descriptor) }
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
        var status = stat()
        #expect(fstat(descriptor, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
    }
}
