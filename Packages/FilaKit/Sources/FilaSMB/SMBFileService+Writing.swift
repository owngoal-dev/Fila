import Darwin
import FilaBackendKit
import FilaLog
import Foundation
import SMBClient

/// The destination side of the neutral contract over one share.
///
/// A file is uploaded to a private name beside its destination and
/// published by the server's own rename, so the destination name never
/// holds half a file and an occupied name is refused by the server in the
/// same request that would have taken it — there is no check-then-rename
/// window. A node is removed one at a time, delete-on-close, and a
/// directory only while the server agrees it is empty; nothing here lists
/// a tree to delete it.
///
/// What SMB2 does not promise is not claimed: a rename that replaces a
/// file is the server's one operation, but a directory at the name is
/// refused rather than replaced, and no ownership, mode or extended
/// attribute travels with the bytes.
extension SMBFileService: WritableFileService {
    /// The most sent in one WRITE. Servers offer up to 8 MiB; one megabyte
    /// keeps an upload's memory flat and its cancellation prompt.
    public static let writeChunk: UInt32 = 1 << 20

    public func createDirectory(_ directory: ServicePath) async throws {
        let wire = try Self.wirePath(directory)
        do {
            try await connection.perform("mkdir", path: directory.description) { client in
                _ = try await client.session.createDirectory(path: wire)
            }
        } catch let error as SMBError {
            throw Self.classify(error, at: directory)
        }
    }

    public func writeFile(
        from descriptor: Int32,
        size: Int64,
        to destination: ServicePath,
        policy: PublishPolicy,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        // The share root is a directory; a file cannot be published there.
        guard let parent = destination.parent else { throw WriteFailure.alreadyExists(destination) }
        let temporary = try parent.appending(".fila-transfer-" + UUID().uuidString)
        let temporaryWire = try Self.wirePath(temporary)
        let targetWire = try Self.wirePath(destination)
        let handle = try await connection.perform("create", path: temporary.description) { client in
            let response = try await client.session.create(
                desiredAccess: [.writeData, .appendData, .readAttributes, .writeAttributes, .synchronize],
                fileAttributes: [.normal],
                shareAccess: [],
                createDisposition: .create,
                createOptions: [.nonDirectoryFile],
                name: temporaryWire
            )
            return SMBConnection.Handle(client: client, fileId: response.fileId, size: 0)
        }
        progress(TransferProgress(completed: 0, expected: size))
        var offset: UInt64 = 0
        do {
            let chunkLength = Int(min(Self.writeChunk, max(handle.client.session.maxWriteSize, 4096)))
            while true {
                try Task.checkCancellation()
                let chunk = try Self.read(descriptor, upTo: chunkLength)
                if chunk.isEmpty { break }
                var written = 0
                while written < chunk.count {
                    let piece = Data(chunk[(chunk.startIndex + written)...])
                    let start = offset
                    let count = try await connection.perform("write", on: handle, path: destination.description) { client in
                        let response = try await client.session.write(data: piece, fileId: handle.fileId, offset: start)
                        return Int(response.count)
                    }
                    // A write that took nothing would loop here forever.
                    guard count > 0 else { throw SMBError.server(status: "WRITE accepted 0 bytes", path: destination.description) }
                    written += count
                    offset += UInt64(count)
                    progress(TransferProgress(completed: Int64(clamping: offset), expected: size))
                }
            }
            await connection.closeHandle(handle)
        } catch {
            // The bytes never reached their name: the handle and the private
            // temporary go, whatever the caller's cancellation state. On a
            // retired session the delete reconnects to do it.
            await connection.closeHandle(handle)
            await discard(temporary)
            if let smb = error as? SMBError { throw Self.classify(smb, at: destination) }
            throw error
        }
        try Task.checkCancellation()
        // Publication: the server's one rename. Exclusive by default — an
        // occupied name is refused by the server in this same request.
        do {
            try await connection.perform("publish", path: destination.description) { client in
                try await client.session.rename(from: temporaryWire, to: targetWire, replaceIfExists: policy == .replace)
            }
        } catch let error as SMBError {
            if error.retiresSession {
                // The request went out and no answer came back. The server
                // may have renamed the file or may not; nothing here guesses.
                FilaLog.warning("smb: publication of \(destination) unanswered; outcome unknown")
                throw WriteFailure.publicationUnknown(destination)
            }
            await discard(temporary)
            throw Self.classify(error, at: destination)
        } catch {
            await discard(temporary)
            throw error
        }
    }

    public func removeFile(_ path: ServicePath) async throws {
        let wire = try Self.wirePath(path)
        do {
            try await connection.perform("unlink", path: path.description) { client in
                try await client.session.deleteNode(path: wire, directory: false)
            }
        } catch let error as SMBError {
            throw Self.classify(error, at: path)
        }
    }

    public func removeEmptyDirectory(_ path: ServicePath) async throws {
        let wire = try Self.wirePath(path)
        do {
            try await connection.perform("rmdir", path: path.description) { client in
                try await client.session.deleteNode(path: wire, directory: true)
            }
        } catch let error as SMBError {
            throw Self.classify(error, at: path)
        }
    }

    public func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        let from = try Self.wirePath(source)
        let to = try Self.wirePath(destination)
        do {
            try await connection.perform("rename", path: source.description) { client in
                try await client.session.rename(from: from, to: to, replaceIfExists: policy == .replace)
            }
        } catch let error as SMBError {
            switch error {
            case .notFound: throw WriteFailure.notFound(source)
            default: throw Self.classify(error, at: destination)
            }
        }
    }

    // MARK: - Pieces

    /// Removes a temporary that never got published. Best effort and
    /// detached from the caller's cancellation, like a close: the request
    /// runs on a fresh session when the current one was retired.
    private func discard(_ temporary: ServicePath) async {
        guard let wire = try? Self.wirePath(temporary) else { return }
        let connection = connection
        let cleanup = Task.detached {
            try await connection.perform("discard", path: temporary.description) { client in
                try await client.session.deleteNode(path: wire, directory: false)
            }
        }
        if (try? await cleanup.value) == nil {
            FilaLog.warning("smb: temporary \(temporary) could not be removed")
        }
    }

    /// The refusals a transfer acts on; everything else stays the SMB
    /// error it was, shown with the server's own status.
    private static func classify(_ error: SMBError, at path: ServicePath) -> Error {
        switch error {
        case .alreadyExists: return WriteFailure.alreadyExists(path)
        case .notFound: return WriteFailure.notFound(path)
        case .directoryNotEmpty: return WriteFailure.notEmpty(path)
        default: return error
        }
    }

    /// Up to `count` bytes from `descriptor`, retrying an interrupted read.
    /// Empty at end of file.
    private static func read(_ descriptor: Int32, upTo count: Int) throws -> Data {
        var buffer = Data(count: count)
        let got = try buffer.withUnsafeMutableBytes { raw -> Int in
            while true {
                let result = Darwin.read(descriptor, raw.baseAddress, count)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SMBError.descriptorRead(code: errno)
                }
                return result
            }
        }
        buffer.count = got
        return buffer
    }
}
