import Foundation

/// Every test here runs against a real directory and real descriptors.
///
/// That is the point: these readers exist to work on a descriptor the daemon
/// opened, they are built on `pread` and `pwrite`, and a fake in front of them
/// would prove nothing about the one thing that can go wrong.
func withScratch(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fila-formats-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

struct OpenFailed: Error {
    var path: String
    var code: Int32
}

func openForReading(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw OpenFailed(path: url.path, code: errno) }
    return descriptor
}

func openForWriting(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else { throw OpenFailed(path: url.path, code: errno) }
    return descriptor
}

/// Runs `body` with a descriptor on `url` and closes it afterwards, which is
/// what keeps a failing expectation from leaking one into the next test.
@discardableResult
func withDescriptor<Result>(reading url: URL, _ body: (Int32) throws -> Result) throws -> Result {
    let descriptor = try openForReading(url)
    defer { close(descriptor) }
    return try body(descriptor)
}

@discardableResult
func withDescriptor<Result>(writing url: URL, _ body: (Int32) throws -> Result) throws -> Result {
    let descriptor = try openForWriting(url)
    defer { close(descriptor) }
    return try body(descriptor)
}

/// Compressible but not trivially so, and long enough to cross several chunks.
func samplePayload(byteCount: Int) -> Data {
    Data((0 ..< byteCount).map { UInt8(($0 &* 7 &+ $0 / 251) % 199) })
}
