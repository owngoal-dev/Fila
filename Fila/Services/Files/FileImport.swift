import FilaFileOps
import FilaProtocol
import Foundation
import UniformTypeIdentifiers

/// Takes ownership of a system picker's file before its temporary URL expires.
/// Only regular files are accepted; publication uses the ordinary copy job.
enum FileImport {
    static func document(_ source: URL, into directory: URL) async throws -> URL {
        try await Task.detached {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<URL, Error> = .failure(FilaFailure(errno: EIO, path: source.path))
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                result = Result { try copy(url, named: source.lastPathComponent, into: directory) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    static func photo(_ provider: NSItemProvider, into directory: URL) async throws -> URL {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { throw FilaFailure(errno: ENOTSUP) }
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw FilaFailure(errno: EIO) }
                    var name = suggestedName ?? url.lastPathComponent
                    if (name as NSString).pathExtension.isEmpty {
                        let suffix = url.pathExtension.isEmpty
                            ? UTType(identifier)?.preferredFilenameExtension
                            : url.pathExtension
                        if let suffix, !suffix.isEmpty { name += "." + suffix }
                    }
                    // The provider deletes its URL when this callback returns.
                    // Finish the clone/copy here, before resuming the caller.
                    continuation.resume(returning: try copy(url, named: name, into: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func copy(_ source: URL, named name: String, into directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FilaFailure(errno: EINVAL, path: name)
        }
        let target = directory.appendingPathComponent(name)
        try FileOperations(bootstrapRoot: "").copyRegularFile(at: source.path, to: target.path)
        return target
    }
}
