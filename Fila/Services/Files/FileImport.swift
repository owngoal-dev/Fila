import FilaBackendUI
import FilaFileOps
import FilaLog
import FilaProtocol
import Foundation
import UniformTypeIdentifiers

/// Takes ownership of a file another app hands over — a picker's, a drop's —
/// before its temporary URL expires. Only regular files are accepted;
/// publication is the caller's, through `FileDelivery`.
enum FileImport {
    static func document(_ source: URL, into directory: URL) async throws -> URL {
        try await Task.detached {
            let accessed = source.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    source.stopAccessingSecurityScopedResource()
                }
            }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<URL, Error> = .failure(FilaFailure(errno: EIO, path: source.path))
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                result = Result { try copy(url, named: source.lastPathComponent, into: directory) }
            }
            if let coordinationError {
                throw coordinationError
            }
            return try result.get()
        }.value
    }

    /// The provider's file of one of `types` — an image from the photo
    /// picker, any file from a drop.
    ///
    /// The load starts before this returns, because a drop's providers must
    /// be asked before `performDrop` does; the closure waits for its arrival.
    /// Cancelling the waiting task, or dropping the closure unused, stops
    /// the load.
    static func item(_ provider: NSItemProvider, conformingTo types: [UTType], into directory: URL) -> @Sendable () async throws -> URL {
        let (arrival, continuation) = AsyncThrowingStream.makeStream(of: URL.self)
        if let identifier = provider.fileTypeIdentifier(conformingTo: types) {
            let suggestedName = provider.suggestedName
            let load = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                continuation.yield(with: Result {
                    if let error {
                        throw error
                    }
                    guard let url else { throw FilaFailure(errno: EIO) }
                    var name = suggestedName ?? url.lastPathComponent
                    if (name as NSString).pathExtension.isEmpty {
                        let suffix = url.pathExtension.isEmpty
                            ? UTType(identifier)?.preferredFilenameExtension
                            : url.pathExtension
                        if let suffix, !suffix.isEmpty {
                            name += "." + suffix
                        }
                    }
                    // The provider deletes its URL when this callback returns.
                    // Finish the clone/copy here, before the caller hears of it.
                    return try copy(url, named: name, into: directory)
                })
                continuation.finish()
            }
            continuation.onTermination = { ending in
                if case .cancelled = ending { load.cancel() }
            }
        } else {
            continuation.finish(throwing: FilaFailure(errno: ENOTSUP))
        }
        return {
            for try await url in arrival {
                return url
            }
            throw CancellationError()
        }
    }

    private static func copy(_ source: URL, named name: String, into directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FilaFailure(errno: EINVAL, path: name)
        }
        let target = directory.appendingPathComponent(name)
        try FileOperations(bootstrapRoot: "").copyRegularFile(at: source.path, to: target.path)
        // The picker's URL expires the moment this returns, so a failed import
        // has no second chance and no trace anywhere else.
        FilaLog.info("imported \(name) into the workspace")
        return target
    }
}
