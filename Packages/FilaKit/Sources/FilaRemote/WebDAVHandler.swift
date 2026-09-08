import FilaProtocol
import Foundation
import NIOHTTP1

/// One connection's worth of WebDAV: read a request, answer it, repeat until
/// the peer goes away.
///
/// The routing, the authentication and the failure translation live here; the
/// verbs themselves are in `WebDAVHandler+Methods.swift`.
struct WebDAVHandler {
    let service: RemoteFileService
    let configuration: WebDAVServer.Configuration
    let nonces: DigestNonces
    let log: @Sendable (String) -> Void

    /// A body this server does not stream — a `PROPFIND` prop list, a `LOCK`
    /// owner — is read and dropped so the next request starts where it should.
    /// Anything larger than this is not one of those, and the connection ends
    /// rather than the app reading it.
    static let discardableBodyByteCount = 1 * 1024 * 1024

    static let allowedMethods = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND"

    // MARK: - Loop

    func serve(_ http: HTTPConnection) async {
        while true {
            do {
                guard let request = try await http.readRequest() else { return }
                let keepsConnection = try await handle(request, on: http)
                try await http.finishResponse()
                guard keepsConnection else { return }
            } catch {
                // Every failure that reaches here is the socket: a peer that
                // hung up, or a request too malformed to answer. Neither is
                // worth a log line on a screen the user reads.
                return
            }
        }
    }

    /// Answers one request. Returns false when the connection must not be
    /// reused — either the client asked for that, or the body was left
    /// unread and what follows on the socket is no longer a request.
    private func handle(_ request: HTTPRequest, on http: HTTPConnection) async throws -> Bool {
        guard isAuthorized(request) else {
            log("\(request.method) \(request.target) — could not sign in")
            try await respond(
                http, 401,
                headers: HTTPAuthentication.challenges(nonces: nonces, for: request)
                    .map { ("WWW-Authenticate", $0) },
                close: true
            )
            return false
        }

        guard Self.hasSameOrigin(request) else {
            try await respond(http, 403, close: true)
            return false
        }

        // Everything but PUT is answered without its body, so the body has to
        // go somewhere before the next request can be read off the socket.
        if request.method != "PUT" {
            guard try await discardBody(request, on: http) else {
                try await respond(http, 413, close: true)
                return false
            }
        }

        // The frontend's own files. Reserved before the share is consulted, so a
        // browser at `/Documents/` can load `/_fila/app.js` whatever the share
        // holds; the cost is that a shared file under `/_fila/` cannot be
        // fetched with GET. Every other method still reaches the share.
        if let name = Self.assetName(request.target), request.method == "GET" || request.method == "HEAD" {
            let status = try await asset(named: name, on: http, includeBody: request.method == "GET")
            log("\(request.method) \(request.target) → \(status)")
            return request.wantsKeepAlive
        }

        guard let path = RemotePath.filesystemPath(for: request.target, root: configuration.root) else {
            log("\(request.method) \(request.target) — the path is not valid")
            try await respond(http, 400, close: request.method == "PUT")
            return request.wantsKeepAlive && request.method != "PUT"
        }
        guard await isServed(path) else {
            log("\(request.method) \(request.target) — not allowed")
            try await respond(http, 403, close: request.method == "PUT")
            return request.wantsKeepAlive && request.method != "PUT"
        }

        // A PUT that failed stopped reading its body where it stood, so what is
        // left on the socket is the middle of a file rather than the start of a
        // request. Every refused PUT therefore ends its connection, and the
        // client opens another — which is what a keep-alive client does anyway.
        let survivesFailure = request.wantsKeepAlive && request.method != "PUT"

        let status: Int
        do {
            status = try await route(request, path: path, on: http)
        } catch let failure as FilaFailure {
            let code = Self.status(for: failure)
            log("\(request.method) \(request.target) → \(code)")
            try await respond(http, code, close: !survivesFailure)
            return survivesFailure
        } catch is HTTPFailure {
            throw HTTPFailure.closed
        } catch {
            log("\(request.method) \(request.target) — request failed")
            try await respond(http, 500, close: !survivesFailure)
            return survivesFailure
        }

        log("\(request.method) \(request.target) → \(status)")
        // Only a failed PUT is fatal to the connection. A 404 is not: Finder
        // probes for `.DS_Store` and `._` files constantly, and tearing the
        // connection down for each would turn a mount into a handshake storm.
        return status >= 400 ? survivesFailure : request.wantsKeepAlive
    }

    private func route(_ request: HTTPRequest, path: String, on http: HTTPConnection) async throws -> Int {
        let mutates = ["PUT", "DELETE", "MKCOL", "MOVE", "COPY"].contains(request.method)
        let unsupportedCondition = request.header("if") != nil
            || request.header("if-match") != nil
            || request.header("if-unmodified-since") != nil
            || (request.method != "PUT" && request.header("if-none-match") != nil)
        if mutates, unsupportedCondition {
            // Checking metadata here and mutating through a later backend call
            // would not make a conditional write atomic. Refuse the unsupported
            // condition rather than silently perform an unconditional mutation.
            try await respond(http, 501, close: request.method == "PUT")
            return 501
        }
        switch request.method {
        case "OPTIONS": return try await options(on: http)
        case "PROPFIND": return try await propfind(request, path: path, on: http)
        case "GET", "HEAD": return try await get(request, path: path, on: http, includeBody: request.method == "GET")
        case "PUT": return try await put(request, path: path, on: http)
        case "DELETE": return try await delete(request, path: path, on: http)
        case "MKCOL": return try await mkcol(request, path: path, on: http)
        case "MOVE": return try await move(request, path: path, on: http)
        case "COPY": return try await copy(request, path: path, on: http)
        default:
            try await respond(http, 405, headers: [("Allow", Self.allowedMethods)])
            return 405
        }
    }

    // MARK: - Frontend assets

    static let assetPrefix = "/_fila/"

    /// `/_fila/app.js` → `app.js`. One plain ASCII filename, nothing hidden and
    /// no separators: the target is matched raw, before any percent-decoding,
    /// so there is no spelling of `..` that reaches `webRoot`'s parent.
    static func assetName(_ target: String) -> String? {
        guard target.hasPrefix(assetPrefix) else { return nil }
        let name = target.dropFirst(assetPrefix.count)
        guard let first = name.first, first != ".",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { return nil }
        return String(name)
    }

    // MARK: - Authentication

    /// Browsers must originate at this listener. Native DAV clients do not
    /// send Origin, and retain their normal authenticated protocol behavior.
    static func hasSameOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.header("origin") else {
            return request.header("sec-fetch-site")?.lowercased() != "cross-site"
        }
        guard let host = request.header("host"),
              let source = URLComponents(string: origin),
              let destination = URLComponents(string: "http://" + host),
              source.scheme?.lowercased() == "http",
              source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil,
              source.path.isEmpty,
              destination.user == nil, destination.password == nil,
              destination.query == nil, destination.fragment == nil,
              destination.path.isEmpty,
              let sourceHost = source.host, let targetHost = destination.host,
              sourceHost.lowercased() == targetHost.lowercased(),
              (source.port ?? 80) == (destination.port ?? 80) else { return false }
        return true
    }

    /// The policy lives in `HTTPAuthentication`, which owns both schemes and
    /// the reasoning about what each is worth.
    func isAuthorized(_ request: HTTPRequest) -> Bool {
        HTTPAuthentication.isAuthorized(
            request,
            username: configuration.username,
            password: configuration.password,
            nonces: nonces
        )
    }

    /// Whether `path` is still inside the served root once symlinks have been
    /// followed.
    ///
    /// `RemotePath` refuses `..` and separators, which is a lexical guarantee
    /// and cannot see a symlink: under a restricted root, a link pointing at
    /// `/etc` would hand `/etc` to whoever asked for the link. The daemon's
    /// `details` answers with the canonical path — `realpath(3)` — which is the
    /// only thing that can tell.
    ///
    /// Skipped when the root is `/`, because nothing can be outside it. That is
    /// what the app always serves, so this costs the device nothing; the extra
    /// round trip is paid only by a caller that asked for a subtree.
    func isServed(_ path: String) async -> Bool {
        guard configuration.root != "/" else { return true }

        // The daemon canonicalises a path's *parents* but reports its last
        // component as `lstat` finds it — a file manager has to be able to show
        // a link rather than what it points at. So an intermediate symlink is
        // already resolved by the time we see the answer, and a final one has
        // to be followed here, once: whatever it names is then canonicalised on
        // its own and resolves everything above itself.
        var subject = path
        if let details = try? await service.details(of: path),
           details.node.kind == .symbolicLink,
           let target = details.node.link?.target
        {
            subject = target.hasPrefix("/")
                ? target
                : RemotePath.join(RemotePath.parent(of: details.path), target)
        }

        // A path that does not exist yet — the target of a `PUT` or a `MKCOL` —
        // is judged by the directory it would be created in. A parent that does
        // not exist either is left to fail as the 404 or 409 it is.
        var resolved = await canonical(subject)
        if resolved == nil {
            resolved = await canonical(RemotePath.parent(of: subject))
        }
        guard let resolved else { return true }
        return resolved == configuration.root || resolved.hasPrefix(configuration.root + "/")
    }

    private func canonical(_ path: String) async -> String? {
        try? await service.details(of: path).path
    }

    // MARK: - Bodies

    /// Reads and drops a body the answer does not depend on. False means it was
    /// too big to drop, and the connection has to end.
    private func discardBody(_ request: HTTPRequest, on http: HTTPConnection) async throws -> Bool {
        if request.isChunked {
            // Thrown out of the sink rather than flagged and kept draining: a
            // chunked body has no declared length, so "too big" has to stop it
            // rather than be noticed once it is over.
            var seen = 0
            do {
                try await http.drainChunkedBody { chunk in
                    seen += chunk.count
                    guard seen <= Self.discardableBodyByteCount else { throw HTTPFailure.tooLarge }
                }
            } catch HTTPFailure.tooLarge {
                return false
            }
            return true
        }
        guard let length = request.contentLength, length > 0 else { return true }
        guard length <= Self.discardableBodyByteCount else { return false }
        try await http.drainBody(count: length) { _ in }
        return true
    }

    // MARK: - Responses

    func respond(
        _ http: HTTPConnection,
        _ status: Int,
        headers: [(String, String)] = [],
        body: Data = Data(),
        close: Bool = false
    ) async throws {
        try await http.write(head(status, headers: headers, contentLength: body.count, close: close))
        try await http.write(body)
    }

    /// The head of a reply whose body is streamed rather than held. Pass a nil
    /// `contentLength` for a chunked one.
    ///
    /// Pairs rather than a dictionary, because a 401 carries two
    /// `WWW-Authenticate` lines and a dictionary cannot hold them.
    func head(
        _ status: Int,
        headers: [(String, String)] = [],
        contentLength: Int?,
        close: Bool = false
    ) -> HTTPResponseHead {
        var fields = HTTPHeaders(headers)
        fields.add(name: "Date", value: HTTPDate.rfc1123(Date().timeIntervalSince1970))
        fields.add(name: "DAV", value: "1")
        fields.add(name: "X-Content-Type-Options", value: "nosniff")
        fields.add(name: "X-Frame-Options", value: "DENY")
        fields.add(name: "Cache-Control", value: "no-store")
        if status >= 200, status != 204, status != 304 {
            if let contentLength {
                fields.add(name: "Content-Length", value: String(contentLength))
            } else {
                fields.add(name: "Transfer-Encoding", value: "chunked")
            }
        }
        if close {
            fields.add(name: "Connection", value: "close")
        }
        return HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: fields)
    }

    /// What a refusal from `filad` means to an HTTP client.
    ///
    /// The guard's own refusal is a 403 and never a 500: it is not a fault, it
    /// is the daemon declining to let a Finder drag delete `/usr`.
    static func status(for failure: FilaFailure) -> Int {
        switch failure.code {
        case .success: return 200
        case .notFound: return 404
        case .protectedPath, .notPermitted, .wrongPassword: return 403
        case .cancelled: return 500
        case .invalidRequest: return 400
        case .operationFailed: break
        }
        switch failure.systemError {
        case ENOENT: return 404
        case EEXIST, ENOTEMPTY: return 412
        case EACCES, EPERM, EROFS: return 403
        case ENOSPC, EDQUOT: return 507
        case ENOTDIR: return 409
        case EISDIR: return 405
        case ENAMETOOLONG: return 400
        default: return 500
        }
    }
}
