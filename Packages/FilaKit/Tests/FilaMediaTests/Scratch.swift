import Foundation

/// Every test here runs against a real directory and real descriptors, for the
/// same reason the format tests do: these generators exist to read through a
/// descriptor the daemon opened, and a fake in front of them would prove nothing
/// about the one thing that can go wrong.
func withScratch(_ body: (URL) throws -> Void) throws {
    let directory = try makeScratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// The same, for the service — which is an actor and so can only be reached
/// with `await`.
func withScratchAsync(_ body: (URL) async throws -> Void) async throws {
    let directory = try makeScratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func makeScratch() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fila-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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

/// Runs `body` with a descriptor on `url` and closes it afterwards, which is
/// what keeps a failing expectation from leaking one into the next test.
@discardableResult
func withDescriptor<Result>(reading url: URL, _ body: (Int32) throws -> Result) throws -> Result {
    let descriptor = try openForReading(url)
    defer { close(descriptor) }
    return try body(descriptor)
}
