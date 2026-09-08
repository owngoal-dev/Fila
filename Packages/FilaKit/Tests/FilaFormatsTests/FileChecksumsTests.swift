import CryptoKit
@testable import FilaFormats
import Foundation
import Testing

@Suite("File checksums")
struct FileChecksumsTests {
    @Test("Three digests cover empty files and multiple chunks", arguments: [0, 3, 700_001])
    func digestValues(count: Int) throws {
        try withScratch { directory in
            let data = Data((0 ..< count).map { UInt8($0 % 251) })
            let file = directory.appendingPathComponent("data")
            try data.write(to: file)
            try withDescriptor(reading: file) { descriptor in
                let result = try FileChecksums.read(descriptor: descriptor)
                func hex<D: Digest>(_ digest: D) -> String {
                    digest.map { String(format: "%02x", $0) }.joined()
                }
                #expect(result.md5 == hex(Insecure.MD5.hash(data: data)))
                #expect(result.sha1 == hex(Insecure.SHA1.hash(data: data)))
                #expect(result.sha256 == hex(SHA256.hash(data: data)))
                #expect(lseek(descriptor, 0, SEEK_CUR) == 0)
            }
        }
    }

    @Test("Cancellation does not produce a partial digest")
    func cancelled() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try withScratch { directory in
                let file = directory.appendingPathComponent("empty")
                try Data().write(to: file)
                try withDescriptor(reading: file) { descriptor in
                    #expect(throws: CancellationError.self) { try FileChecksums.read(descriptor: descriptor) }
                }
            }
        }
        try await task.value
    }
}
