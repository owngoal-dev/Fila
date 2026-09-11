import Darwin
import FilaProtocol
import Foundation
import UniformTypeIdentifiers

/// GET and HEAD: a file's bytes, the browser page that stands in for a
/// directory listing, the frontend's own assets, and the byte pump all of them
/// share.
///
/// The descriptor is the whole design here — `filad` opens it as root and
/// forgets it, and the bytes travel from the kernel to the socket without
/// passing through the daemon.
extension WebDAVHandler {
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
        if let item = Self.typeIconRequest(name) {
            return try await typeIcon(for: item, on: http, includeBody: includeBody)
        }
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

    // MARK: - Bytes

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
