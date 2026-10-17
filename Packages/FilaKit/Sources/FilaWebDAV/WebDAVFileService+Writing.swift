import FilaBackendKit
import FilaLog
import Foundation

/// The destination side of the neutral contract over one WebDAV server.
///
/// A file is uploaded with `PUT` to a private name beside its destination
/// and published with the server's own `MOVE`, so the destination name
/// never holds half a file, and `Overwrite: F` makes an occupied name the
/// server's refusal in the same request that would have taken it.
///
/// What WebDAV does not promise is not claimed, and where the protocol is
/// more dangerous than the contract the difference is closed as far as the
/// protocol allows:
///
/// - `MOVE` with `Overwrite: T` deletes what is at the destination before
///   it moves (RFC 4918 §9.9.3). A replacement is therefore not atomic on
///   any server, and a folder at the destination would be deleted with
///   everything in it, so `.replace` looks first and refuses a folder.
/// - `DELETE` of a collection is recursive by definition (§9.6.1) and there
///   is no "only if empty". A folder is removed only after a listing showed
///   it empty, and both removals carry the item's ETag as `If-Match` when
///   the server gave one, so an item swapped in between is refused by a
///   server that honours the condition. A server that ignores it leaves the
///   moment between the look and the removal open; nothing else can close it.
///
/// No ownership, mode or extended attribute travels with the bytes.
extension WebDAVFileService: WritableFileService {
    public func createDirectory(_ directory: ServicePath) async throws {
        var request = URLRequest(url: transport.url(for: directory.components, collection: true))
        request.httpMethod = "MKCOL"
        let reply = try await send(request, path: directory)
        switch reply.status {
        case 200 ..< 300: return
        case 405: throw WriteFailure.alreadyExists(directory)
        case 409: throw WriteFailure.notFound(directory)
        default: throw Self.classify(Self.refusal(reply, path: directory), at: directory)
        }
    }

    public func writeFile(
        from descriptor: Int32,
        size: Int64,
        to destination: ServicePath,
        policy: PublishPolicy,
        progress: @escaping @Sendable (TransferProgress) -> Void,
    ) async throws {
        // The root is a folder; a file cannot be published there.
        guard let parent = destination.parent else { throw WriteFailure.alreadyExists(destination) }
        let temporary = try parent.appending(".fila-transfer-" + UUID().uuidString)

        // A refusal the server will give at publication is asked for first,
        // so a large file is not sent only to be thrown away. The move's own
        // `Overwrite: F` stays the guard that decides.
        try await checkDestination(destination, policy: policy)

        progress(TransferProgress(completed: 0, expected: size))
        var request = URLRequest(url: transport.url(for: temporary.components, collection: false))
        request.httpMethod = "PUT"
        // No `If-None-Match: *`: the name is a fresh UUID, and a server that
        // does not implement conditions may refuse the whole PUT.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let upload = WebDAVTransport.Upload(descriptor: descriptor, size: size) { sent in
            progress(TransferProgress(completed: sent, expected: size))
        }
        // Whatever stops the upload, the temporary goes, whatever the
        // caller's cancellation state.
        let reply: WebDAVTransport.Reply
        do {
            reply = try await transport.send(request, upload: upload)
        } catch {
            // An upload cut short — cancelled, or lost on the way — may still
            // be finishing on the other end; one the connection never
            // carried cannot be.
            await discard(temporary, interrupted: error is CancellationError || WebDAVError.mayHaveBeenSent(error))
            if error is CancellationError {
                throw error
            }
            throw WebDAVError.map(error)
        }
        guard reply.isSuccess else {
            // A refusal is the server's last word on the temporary.
            await discard(temporary)
            if reply.status == 409 {
                throw WriteFailure.notFound(destination)
            }
            throw Self.classify(Self.refusal(reply, path: destination), at: destination)
        }
        // The server has every byte; the session's last send report may not
        // have said so yet.
        progress(TransferProgress(completed: size, expected: size))

        // Publication. The cancellation check sits before it, so a cancel
        // landing between the upload and the move still takes the temporary
        // with it. Past that check the move runs in a task of its own, out
        // of the caller's cancellation: a cancel that reached it on the wire
        // could not say whether the server moved, and would report as not
        // published a file that was.
        do {
            try Task.checkCancellation()
            if policy == .replace {
                try await refuseFolder(at: destination)
            }
            try await publish(temporary, to: destination, replace: policy == .replace)
        } catch let failure as WriteFailure {
            if case .publicationUnknown = failure {
                throw failure
            }
            await discard(temporary)
            throw failure
        } catch {
            await discard(temporary)
            throw error
        }
    }

    public func removeFile(_ path: ServicePath) async throws {
        let resource: WebDAVResource?
        do {
            resource = try await propfind(path, depth: "0", collection: false).first
        } catch let error as WebDAVError {
            throw Self.classify(error, at: path)
        }
        guard let resource, !resource.isCollection else { throw WebDAVError.wrongKind(path: path.description) }
        try await delete(path, collection: false, etag: resource.etag)
    }

    public func removeEmptyDirectory(_ path: ServicePath) async throws {
        let members: (own: WebDAVResource?, children: [FileEntry], others: Int)
        do {
            members = try await self.members(of: path)
        } catch let error as WebDAVError {
            throw Self.classify(error, at: path)
        }
        guard let own = members.own, own.isCollection else { throw WebDAVError.wrongKind(path: path.description) }
        // Depth: infinity takes everything inside, so anything the server
        // answered besides the folder — listed, unreadable or skipped —
        // means it is not empty.
        guard members.others == 0 else { throw WriteFailure.notEmpty(path) }
        try await delete(path, collection: true, etag: own.etag)
    }

    public func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        // A folder is moved by its collection URL, slash and all: servers
        // refuse or redirect a collection named without one.
        let sourceKind: FileEntry.Kind
        do {
            sourceKind = try await details(source).kind
        } catch WebDAVError.notFound {
            throw WriteFailure.notFound(source)
        }
        if policy == .replace {
            try await refuseFolder(at: destination)
        }
        let collection = sourceKind == .directory
        var request = URLRequest(url: transport.url(for: source.components, collection: collection))
        request.httpMethod = "MOVE"
        request.setValue(
            transport.url(for: destination.components, collection: collection).absoluteString,
            forHTTPHeaderField: "Destination",
        )
        request.setValue(policy == .replace ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let reply = try await send(request, path: source)
        switch reply.status {
        case 200 ..< 300 where reply.status != 207: return
        case 404: throw WriteFailure.notFound(source)
        case 412: throw WriteFailure.alreadyExists(destination)
        case 409: throw WriteFailure.notFound(destination)
        default: throw Self.classify(Self.refusal(reply, path: source), at: source)
        }
    }

    // MARK: - Pieces

    /// What publication under `policy` would refuse, refused before any
    /// byte is sent: an occupied name for an exclusive write, a folder for
    /// a replacement.
    private func checkDestination(_ destination: ServicePath, policy: PublishPolicy) async throws {
        let kind: FileEntry.Kind
        do {
            kind = try await details(destination).kind
        } catch WebDAVError.notFound {
            return
        }
        switch policy {
        case .failIfExists: throw WriteFailure.alreadyExists(destination)
        case .replace where kind == .directory: throw WriteFailure.notEmpty(destination)
        case .replace: return
        }
    }

    /// A replacement must never delete a folder: `Overwrite: T` would take
    /// it and everything in it. A free name is fine.
    private func refuseFolder(at destination: ServicePath) async throws {
        do {
            if try await details(destination).kind == .directory {
                throw WriteFailure.notEmpty(destination)
            }
        } catch WebDAVError.notFound {
            return
        }
    }

    /// One `DELETE`, conditioned on `etag` when it is a strong one. A server that
    /// says it does not implement the condition (501) is asked again
    /// without it, which is what a server that ignores it does anyway. A
    /// 207 is a removal that failed part-way inside the server and is
    /// reported as the refusal it is.
    private func delete(_ path: ServicePath, collection: Bool, etag: String?) async throws {
        var request = URLRequest(url: transport.url(for: path.components, collection: collection))
        request.httpMethod = "DELETE"
        if collection {
            request.setValue("infinity", forHTTPHeaderField: "Depth")
        }
        // If-Match compares strongly (RFC 9110 §13.1.1): a weak or unquoted
        // tag would never match, and every removal would be refused.
        let condition = etag.flatMap { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 ? $0 : nil }
        if let condition {
            request.setValue(condition, forHTTPHeaderField: "If-Match")
        }
        var reply = try await send(request, path: path)
        if reply.status == 501, condition != nil {
            request.setValue(nil, forHTTPHeaderField: "If-Match")
            reply = try await send(request, path: path)
        }
        switch reply.status {
        case 200 ..< 300 where reply.status != 207: return
        default: throw Self.classify(Self.refusal(reply, path: path), at: path)
        }
    }

    /// The server's own `MOVE` from the private name, sent outside the
    /// caller's cancellation. A request that may have reached the server
    /// and got no answer is `publicationUnknown`; nothing here guesses.
    private func publish(_ temporary: ServicePath, to destination: ServicePath, replace: Bool) async throws {
        var request = URLRequest(url: transport.url(for: temporary.components, collection: false))
        request.httpMethod = "MOVE"
        request.setValue(transport.url(for: destination.components, collection: false).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(replace ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let transport = transport
        let reply: WebDAVTransport.Reply
        do {
            reply = try await Task.detached { try await transport.send(request) }.value
        } catch {
            if WebDAVError.mayHaveBeenSent(error) {
                FilaLog.warning("webdav: publication of \(destination) unanswered; outcome unknown")
                throw WriteFailure.publicationUnknown(destination)
            }
            throw WebDAVError.map(error)
        }
        switch reply.status {
        case 200 ..< 300 where reply.status != 207: return
        case 412: throw WriteFailure.alreadyExists(destination)
        case 409: throw WriteFailure.notFound(destination)
        default: throw Self.classify(Self.refusal(reply, path: destination), at: destination)
        }
    }

    /// Removes a temporary that never got published. Best effort and
    /// detached from the caller's cancellation.
    ///
    /// An upload that was `interrupted` — cancelled or cut off rather than
    /// refused — may have handed the server its last byte just before, and
    /// the server then publishes the temporary after this process gave up
    /// on it. When the first removal finds nothing to remove, the name is
    /// looked at again for a few seconds in the background, without holding
    /// up the caller, and removed if it appears.
    private func discard(_ temporary: ServicePath, interrupted: Bool = false) async {
        var request = URLRequest(url: transport.url(for: temporary.components, collection: false))
        request.httpMethod = "DELETE"
        let transport = transport
        let first = try? await Task.detached { try await transport.send(request) }.value
        if let first, first.isSuccess {
            return
        }
        guard interrupted else {
            if first?.status != 404 {
                FilaLog.warning("webdav: temporary \(temporary) could not be removed")
            }
            return
        }
        Task.detached {
            for _ in 0 ..< 3 {
                try? await Task.sleep(nanoseconds: 750_000_000)
                if let reply = try? await transport.send(request), reply.isSuccess {
                    return
                }
            }
        }
    }

    /// The refusals a transfer acts on; everything else stays the WebDAV
    /// error it was.
    private static func classify(_ error: WebDAVError, at path: ServicePath) -> Error {
        switch error {
        case .notFound: WriteFailure.notFound(path)
        case .alreadyExists: WriteFailure.alreadyExists(path)
        default: error
        }
    }
}
