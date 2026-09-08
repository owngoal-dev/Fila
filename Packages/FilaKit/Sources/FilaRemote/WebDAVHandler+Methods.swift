import Darwin
import FilaFileOps
import FilaProtocol
import Foundation
import UniformTypeIdentifiers

/// The verbs.
///
/// Every one of them reaches the filesystem through `RemoteFileService`, which
/// selects the privileged or in-process backend. This file never opens,
/// renames or unlinks a filesystem path itself,
/// and `FilaGuard` therefore sees a request that arrived over the network the
/// same way it sees a swipe in the browser.
extension WebDAVHandler {
    // MARK: - OPTIONS

    func options(on http: HTTPConnection) async throws -> Int {
        try await respond(http, 200, headers: [
            ("Allow", Self.allowedMethods),
            ("Accept-Ranges", "bytes"),
            // Without this macOS mounts the volume read-only and offers no
            // explanation for it anywhere the user can see.
            ("MS-Author-Via", "DAV"),
        ])
        return 200
    }

    // MARK: - PROPFIND

    func propfind(_ request: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        // `Depth: infinity` on `/` is a walk of the whole device answered as one
        // document. Refusing it with the error the specification defines is what
        // makes a client ask again a level at a time instead of hanging.
        guard request.depth == "0" || request.depth == "1" else {
            try await respond(
                http, 403,
                headers: [("Content-Type", "application/xml; charset=\"utf-8\"")],
                body: Data(DAVXML.finiteDepthError.utf8)
            )
            return 403
        }

        // Everything that can fail is asked for before a byte of the reply is
        // written: once the 207 is on the wire there is no status code left to
        // change our mind with.
        let details = try await service.details(of: path)
        let isCollection = details.node.isNavigable
        let children = request.depth == "1" && isCollection ? try await service.list(path) : []

        try await stream {
            try await http.write(head(207, headers: [
                ("Content-Type", "application/xml; charset=\"utf-8\""),
            ], contentLength: nil))
            try await http.write(Data(DAVXML.multistatusOpen.utf8))
            try await http.write(Data(DAVXML.response(
                href: RemotePath.href(for: path, root: configuration.root, isCollection: isCollection),
                node: details.node,
                isCollection: isCollection
            ).utf8))

            // Batched rather than one chunk per entry, and flushed rather than
            // joined: a directory with a hundred thousand entries is a normal
            // thing to find on a phone, and neither the string nor the socket
            // buffer is allowed to grow with it.
            var batch = ""
            for entry in children {
                batch += DAVXML.response(
                    href: RemotePath.href(
                        for: RemotePath.join(path, entry.name),
                        root: configuration.root,
                        isCollection: entry.isNavigable
                    ),
                    node: entry,
                    isCollection: entry.isNavigable
                )
                if batch.utf8.count >= 64 * 1024 {
                    try await http.write(Data(batch.utf8))
                    batch = ""
                }
            }
            try await http.write(Data(batch.utf8))
            try await http.write(Data(DAVXML.multistatusClose.utf8))
            try await http.finishResponse()
        }
        return 207
    }

    // MARK: - GET / HEAD

    func get(_ request: HTTPRequest, path: String, on http: HTTPConnection, includeBody: Bool) async throws -> Int {
        let details = try await service.details(of: path)
        if details.node.isNavigable {
            return try await index(on: http, includeBody: includeBody)
        }

        let kind = details.node.link?.resolvedKind ?? details.node.kind
        guard kind == .regular else {
            try await respond(http, 403)
            return 403
        }
        if let side = Self.thumbnailSide(in: request.target) {
            return try await thumbnail(path: path, side: side, node: details.node, on: http, includeBody: includeBody)
        }

        // The descriptor is the whole design: `filad` opened it as root and
        // forgot it, and every byte below travels from the kernel to the socket
        // without passing through the daemon. It is also why a 4 GB file costs
        // the same memory here as a 4 KB one.
        let descriptor = try await service.open(path, flags: O_RDONLY | O_NONBLOCK, mode: 0)
        defer { close(descriptor) }

        var found = stat()
        guard fstat(descriptor, &found) == 0 else {
            throw FilaFailure(code: .operationFailed, systemError: errno, path: path)
        }
        // Recheck the descriptor: the directory entry may have changed after
        // details. Nonblocking open also keeps a raced-in FIFO from hanging.
        guard found.st_mode & S_IFMT == S_IFREG, found.st_size >= 0 else {
            try await respond(http, 403)
            return 403
        }
        let size = Int64(found.st_size)
        let modified = Double(found.st_mtimespec.tv_sec) + Double(found.st_mtimespec.tv_nsec) / 1_000_000_000

        var headers = [
            ("Accept-Ranges", "bytes"),
            ("Content-Type", Self.contentType(of: path)),
            // Shared files may themselves contain HTML/JavaScript. They must
            // download rather than execute with this server's credentials.
            ("Content-Disposition", "attachment"),
            ("Content-Security-Policy", "sandbox; default-src 'none'"),
            ("Last-Modified", HTTPDate.rfc1123(modified)),
            ("ETag", DAVXML.entityTag(inode: UInt64(found.st_ino), size: size, modified: modified)),
        ]

        var offset: Int64 = 0
        var count = size
        var status = 200
        // Our validator is weak and cannot authorize resuming an old download.
        // If-Range therefore falls back to the complete current representation.
        let range = request.header("if-range") == nil ? request.header("range") : nil
        switch ByteRange.parse(range, fileSize: size) {
        case .absent:
            break
        case let .range(range):
            offset = range.offset
            count = range.count
            status = 206
            headers.append(("Content-Range", "bytes \(offset)-\(offset + count - 1)/\(size)"))
        case .unsatisfiable:
            try await respond(http, 416, headers: [("Content-Range", "bytes */\(size)")])
            return 416
        }

        try await stream {
            try await http.write(head(status, headers: headers, contentLength: Int(count)))
            guard includeBody else { return }
            try await send(descriptor: descriptor, offset: offset, count: count, to: http)
        }
        return status
    }

    /// A directory in a browser. Not part of WebDAV — it is what makes
    /// `http://<phone>:8080/` useful from a laptop that is not mounting
    /// anything, which is half of what people use this feature for.
    ///
    /// The page is the same for every directory — it reads its location from
    /// the URL — and it may load script and style only from `/_fila/`, its
    /// own origin: nothing inline, so a shared file's content can never become
    /// part of the page.
    private func index(on http: HTTPConnection, includeBody: Bool) async throws -> Int {
        guard let webRoot = configuration.webRoot else {
            try await respond(http, 404)
            return 404
        }
        return try await serveLocal(
            webRoot.appendingPathComponent("index.html"),
            contentType: "text/html; charset=utf-8",
            headers: [
                ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
            ],
            on: http,
            includeBody: includeBody
        )
    }

    /// One file of the frontend, by the name `assetName` already vetted.
    /// Only the types a build emits are served; `index.html` is reachable
    /// solely through a directory GET, where it gets its CSP.
    func asset(named name: String, on http: HTTPConnection, includeBody: Bool) async throws -> Int {
        let types = [
            "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "map": "application/json",
            "png": "image/png",
        ]
        guard let webRoot = configuration.webRoot,
              let contentType = types[(name as NSString).pathExtension.lowercased()]
        else {
            try await respond(http, 404)
            return 404
        }
        return try await serveLocal(
            webRoot.appendingPathComponent(name),
            contentType: contentType,
            headers: [],
            on: http,
            includeBody: includeBody
        )
    }

    /// A file of the app's own bundle, read with this process's rights. Not the
    /// user's data, so `service` is not involved; a bundle is immutable while
    /// the app runs, which is why size from `fstat` is trusted for the length.
    private func serveLocal(
        _ url: URL,
        contentType: String,
        headers: [(String, String)],
        on http: HTTPConnection,
        includeBody: Bool
    ) async throws -> Int {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            try await respond(http, 404)
            return 404
        }
        defer { close(descriptor) }
        var found = stat()
        guard fstat(descriptor, &found) == 0, found.st_mode & S_IFMT == S_IFREG else {
            try await respond(http, 404)
            return 404
        }
        let size = Int64(found.st_size)
        try await stream {
            try await http.write(head(
                200,
                headers: [("Content-Type", contentType), ("Cache-Control", "no-cache")] + headers,
                contentLength: Int(size)
            ))
            guard includeBody else { return }
            try await send(descriptor: descriptor, offset: 0, count: size, to: http)
        }
        return 200
    }

    // MARK: - PUT

    func put(_ request: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        let parent = RemotePath.parent(of: path)
        // A PUT into a directory that does not exist is a 409 and never an
        // implicit `mkdir -p`: the client asked for one thing and inventing the
        // rest of the tree for it is how a typo becomes a directory at `/`.
        guard let holder = try? await service.details(of: parent), holder.node.isNavigable else {
            try await respond(http, 409)
            return 409
        }
        let exclusive: Bool
        if let condition = request.header("if-none-match") {
            guard condition.trimmed == "*" else {
                try await respond(http, 412, close: true)
                return 412
            }
            exclusive = true
        } else {
            exclusive = false
        }
        let existing = try? await service.details(of: path)
        if exclusive && existing != nil {
            try await respond(http, 412, close: true)
            return 412
        }
        if let existing, existing.node.isNavigable {
            try await respond(http, 405, headers: [("Allow", Self.allowedMethods)])
            return 405
        }
        guard request.isChunked || request.contentLength != nil else {
            try await respond(http, 411, close: true)
            return 411
        }
        if request.expectsContinue {
            try await http.write(head(100, contentLength: nil))
        }

        // The same shape as every other write in this app: a temporary beside
        // the target, then `replaceItem`, which carries the original's mode,
        // owner, times, xattrs and flags across and `rename(2)`s. A truncating
        // write here would let a dropped Wi-Fi connection halve a system plist.
        let temporary = RemotePath.join(parent, ".fila-tmp-\(UUID().uuidString)")
        // Keep incomplete uploads private; publication applies the new-file
        // defaults or preserves the existing destination’s metadata.
        let descriptor = try await service.open(
            temporary,
            flags: O_CREAT | O_EXCL | O_WRONLY,
            mode: 0o600
        )

        // Two `do` blocks, and the split is not cosmetic. The descriptor has to
        // be closed exactly once, and `replaceItem` is a round trip: a single
        // block that closed on the way out and again in its `catch` would close
        // a number that another connection — or a download's write — has
        // already been handed by the kernel in between. That is somebody else's
        // file being written to, not an error.
        do {
            let sink: (Data) throws -> Void = { try Self.write($0, to: descriptor) }
            if request.isChunked {
                try await http.drainChunkedBody(into: sink)
            } else {
                try await http.drainBody(count: request.contentLength ?? 0, into: sink)
            }
            while fsync(descriptor) != 0 {
                if errno != EINTR {
                    throw FilaFailure(code: .operationFailed, systemError: errno, path: path)
                }
            }
        } catch {
            close(descriptor)
            await discard(temporary)
            throw error
        }
        close(descriptor)

        do {
            if exclusive {
                // The backend publishes with RENAME_EXCL. A file arriving
                // during this upload must remain untouched, even after the
                // earlier existence check succeeded.
                try await service.setAttributes(.newItemDefaults, at: temporary)
                try await service.rename(temporary, to: path, exclusive: true)
            } else {
                try await service.replaceItem(at: path, withTemporary: temporary)
            }
        } catch {
            await discard(temporary)
            throw error
        }

        let status = existing == nil ? 201 : 204
        try await respond(http, status)
        return status
    }

    /// Removes a temporary a failed operation left behind. Best effort — the
    /// request has already failed and the client is about to be told so — and
    /// permanently rather than to the trash: nobody wants a dotfile from a
    /// broken upload in there, and it was never anything the user had.
    private func discard(_ temporary: String) async {
        try? await service.run(JobRequest(kind: .delete, sources: [temporary]))
    }

    // MARK: - DELETE

    func delete(_: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        // The daemon refuses the volume root anyway; this is here so a
        // restricted root — the harness's scratch directory — is refused too.
        guard path != configuration.root else {
            try await respond(http, 403)
            return 403
        }
        // Asked before the job rather than left to `removefile`'s ENOENT.
        // A mounted Finder window probes for `.DS_Store` and `._` files it has
        // never written, and every probe would otherwise open a delete job and
        // leave a failed row in the transfers list.
        _ = try await service.details(of: path)
        // WebDAV has no Put Back flow. The browser confirms permanent deletion,
        // independently of the app's preference for its own file browser.
        try await service.run(JobRequest(kind: .delete, sources: [path], useTrash: false))
        try await respond(http, 204)
        return 204
    }

    // MARK: - MKCOL

    func mkcol(_: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        guard let holder = try? await service.details(of: RemotePath.parent(of: path)), holder.node.isNavigable else {
            try await respond(http, 409)
            return 409
        }
        do {
            try await service.create(.directory, at: path)
        } catch let failure as FilaFailure where failure.systemError == EEXIST {
            try await respond(http, 405, headers: [("Allow", Self.allowedMethods)])
            return 405
        }
        try await respond(http, 201)
        return 201
    }

    // MARK: - MOVE / COPY

    func move(_ request: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        guard let destination = destination(of: request) else {
            try await respond(http, 400)
            return 400
        }
        guard destination != configuration.root, await isServed(destination) else {
            try await respond(http, 403)
            return 403
        }
        let occupied = await exists(destination)
        guard request.allowsOverwrite || !occupied else {
            try await respond(http, 412)
            return 412
        }

        do {
            // Exclusive when the client said not to overwrite, so the answer
            // comes from the kernel rather than from the check above — which is
            // already stale by the time the rename runs.
            try await service.rename(path, to: destination, exclusive: !request.allowsOverwrite)
        } catch let failure as FilaFailure where failure.systemError == EEXIST {
            try await respond(http, 412)
            return 412
        } catch let failure as FilaFailure where failure.systemError == EXDEV {
            // Different volumes. `rename(2)` cannot, `copyfile(3)` can, and the
            // daemon's move job is the thing that knows which.
            try await transfer(.move, from: path, to: destination, overwrite: request.allowsOverwrite)
        }
        let status = occupied ? 204 : 201
        try await respond(http, status)
        return status
    }

    func copy(_ request: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        guard let destination = destination(of: request) else {
            try await respond(http, 400)
            return 400
        }
        guard destination != configuration.root, await isServed(destination) else {
            try await respond(http, 403)
            return 403
        }
        let occupied = await exists(destination)
        guard request.allowsOverwrite || !occupied else {
            try await respond(http, 412)
            return 412
        }
        try await transfer(.copy, from: path, to: destination, overwrite: request.allowsOverwrite)
        let status = occupied ? 204 : 201
        try await respond(http, status)
        return status
    }

    /// Whether anything is at `path`.
    ///
    /// Only ever used to choose between 201 and 204 and to refuse an
    /// `Overwrite: F` early. It is never what actually protects the
    /// destination — the exclusive rename inside the operation is, because this
    /// answer is stale the moment it arrives.
    private func exists(_ path: String) async -> Bool {
        await (try? service.details(of: path)) != nil
    }

    /// Copy or move one node to an exact path.
    ///
    /// The daemon's jobs land their sources *in* a directory under their own
    /// names, and WebDAV names the result exactly — `COPY` is how Finder
    /// duplicates a file, and the duplicate is not called the same thing. So
    /// the work lands in a staging directory beside the destination and is then
    /// renamed into place: same directory, so the rename is atomic, and no name
    /// but the one the client asked for is ever occupied on the way.
    ///
    /// The alternative — copying straight into the destination's parent and
    /// renaming afterwards — would clobber whatever already sits at the
    /// source's own name there, which for a duplicate is the original.
    ///
    /// **A `.move` has already destroyed the source by the time the rename
    /// runs** — the daemon's move job copies the tree and then removes it — so
    /// between those two lines the staging directory holds the user's only
    /// copy. Everything the failure path does is shaped by that: it puts the
    /// staged tree back where it came from, and it deletes the staging
    /// directory only once it is empty.
    private func transfer(
        _ kind: FilaJobKind,
        from source: String,
        to destination: String,
        overwrite: Bool
    ) async throws {
        let staging = RemotePath.join(RemotePath.parent(of: destination), ".fila-dav-\(UUID().uuidString)")
        let staged = RemotePath.join(staging, RemotePath.name(of: source))
        try await service.create(.directory, at: staging)
        do {
            try await service.run(JobRequest(kind: kind, sources: [source], destination: staging))
            try await service.rename(staged, to: destination, exclusive: !overwrite)
        } catch {
            await unstage(staged, back: kind == .move ? source : nil, removing: staging)
            throw error
        }
        // Empty now: the rename took the one entry out of it.
        try? await service.run(JobRequest(kind: .delete, sources: [staging]))
    }

    /// Undoes a `transfer` that failed part-way.
    ///
    /// `origin` is non-nil only for a move, whose source is already gone. The
    /// staged tree is put back there first, and the staging directory is
    /// removed only if that succeeded — a recursive delete over the user's only
    /// copy is the one thing this must never do, so when it cannot be returned
    /// it is left where it is for them to find.
    private func unstage(_ staged: String, back origin: String?, removing staging: String) async {
        if let origin {
            do {
                try await service.rename(staged, to: origin, exclusive: true)
            } catch {
                log("Unable to finish the move. Your files are in \(staged).")
                return
            }
        }
        try? await service.run(JobRequest(kind: .delete, sources: [staging]))
    }

    private func destination(of request: HTTPRequest) -> String? {
        guard let header = request.header("destination") else { return nil }
        if !header.hasPrefix("/") {
            guard let target = URLComponents(string: header),
                  let host = request.header("host"),
                  let local = URLComponents(string: "http://" + host),
                  target.scheme?.lowercased() == "http",
                  target.user == nil, target.password == nil,
                  target.query == nil, target.fragment == nil,
                  let targetHost = target.host, let localHost = local.host,
                  targetHost.lowercased() == localHost.lowercased(),
                  (target.port ?? 80) == (local.port ?? 80) else { return nil }
        } else if header.hasPrefix("//") {
            return nil
        }
        return RemotePath.filesystemPath(for: header, root: configuration.root)
    }

    // MARK: - Bytes

    /// Once a reply's head is on the wire there is no status code left to send,
    /// so anything that fails from here is the connection and nothing else.
    func stream(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            throw HTTPFailure.closed
        }
    }

    /// `pread` a window of the file into a fixed buffer and send it, until the
    /// window is done. Flat memory, and `Range` support falls out of it.
    ///
    /// ponytail: the `pread` is synchronous on the task's thread. Local flash
    /// makes each one microseconds and `WebDAVServer.connectionLimit` bounds
    /// how many can be in one at a time; hand it to a detached task the day
    /// this server has to serve a network mount rather than a phone.
    private func send(descriptor: Int32, offset: Int64, count: Int64, to http: HTTPConnection) async throws {
        var buffer = [UInt8](repeating: 0, count: HTTPConnection.chunkByteCount)
        var sent: Int64 = 0
        while sent < count {
            let want = Int(min(Int64(buffer.count), count - sent))
            let got = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress, want, off_t(offset + sent))
            }
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw FilaFailure(code: .operationFailed, systemError: errno)
            }
            // Short of what the header promised. The file was truncated under
            // us; the connection has to die, because the client is counting.
            if got == 0 {
                throw HTTPFailure.closed
            }
            try await http.write(Data(buffer[0 ..< got]))
            sent += Int64(got)
        }
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try StorageSpace.requireAvailable(Int64(data.count), descriptor: descriptor)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let put = Darwin.write(descriptor, base + written, raw.count - written)
                if put < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw FilaFailure(code: .operationFailed, systemError: errno)
                }
                if put == 0 {
                    throw FilaFailure(code: .operationFailed, systemError: ENOSPC)
                }
                written += put
            }
        }
    }

    /// The system's MIME type accompanies the downloaded attachment so the
    /// receiving application can identify it; a DAV mount may ignore it.
    static func contentType(of path: String) -> String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }
}
