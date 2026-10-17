import FilaBackendKit
import FilaLog
import Foundation

/// The neutral file contract over one WebDAV server.
///
/// Every path is relative to the profile's address and goes on the wire as
/// percent-encoded components, so a name is always one name; nothing here
/// resolves, normalises or cases a name. A file is read straight into the
/// caller's descriptor as it arrives, so no operation holds a file in
/// memory whatever its size.
///
/// A directory is listed with one `PROPFIND` of depth 1. WebDAV has no
/// paging, so the listing arrives in one reply, held to
/// `WebDAVTransport.collectLimit`. WebDAV has no links either: every entry
/// is a file or a folder.
public final class WebDAVFileService: FileService, @unchecked Sendable {
    let transport: WebDAVTransport
    /// What the root's own entry is called: the profile's display name.
    let rootName: String
    /// What `changes(in:)` polls through. Main-actor, as every observation
    /// owner is: the subscriptions are UI state.
    public let observation: RemoteDirectoryObservation

    init(transport: WebDAVTransport, rootName: String, observation: RemoteDirectoryObservation) {
        self.transport = transport
        self.rootName = rootName
        self.observation = observation
    }

    /// A service over `profile` with `password`, polling every `interval`.
    /// Nil when the profile's address is not usable.
    public convenience init?(
        profile: WebDAVProfile,
        password: String?,
        pollInterval: TimeInterval = RemoteDirectoryObservation.pollInterval,
        requestTimeout: TimeInterval = 30,
    ) {
        guard let baseURL = profile.baseURL else { return nil }
        self.init(
            transport: WebDAVTransport(
                baseURL: baseURL,
                username: profile.username,
                password: password,
                requestTimeout: requestTimeout,
            ),
            rootName: profile.displayName,
            observation: RemoteDirectoryObservation(interval: pollInterval),
        )
    }

    /// Ends the session and every change stream: what the backend does when
    /// its profile is edited away or removed.
    public func disconnect() async {
        transport.close()
        await MainActor.run { observation.finishAll(throwing: WebDAVError.disconnected) }
    }

    /// Hints subscribers of `directories` that this process changed them.
    @MainActor
    public func invalidate(_ directories: [ServicePath]) {
        observation.invalidate(directories.map(\.description))
    }

    // MARK: - FileService

    public func list(_ directory: ServicePath) async throws -> FileListing {
        FileListing { [self] in
            let delivered = Delivered()
            return FileListing.Source(
                next: {
                    guard delivered.take() else { return nil }
                    return try await self.entries(in: directory)
                },
                close: {},
            )
        }
    }

    public func details(_ path: ServicePath) async throws -> FileEntry {
        let resources = try await propfind(path, depth: "0", collection: false)
        guard let resource = resources.first else { throw WebDAVError.invalidResponse }
        return entry(for: resource, name: path.name ?? rootName)
    }

    public func copyContents(
        of path: ServicePath,
        to descriptor: Int32,
        progress: @escaping @Sendable (TransferProgress) -> Void,
    ) async throws {
        var request = URLRequest(url: transport.url(for: path.components, collection: false))
        request.httpMethod = "GET"
        // The bytes as stored: a compressed transfer would make the count
        // disagree with the size and the progress with the file.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        progress(TransferProgress(completed: 0, expected: nil))
        let reply = try await send(request, path: path, sink: .descriptor(descriptor) { written, expected in
            progress(TransferProgress(completed: written, expected: expected))
        })
        guard reply.status == 200 else {
            throw Self.refusal(reply, path: path)
        }
    }

    public func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> {
        await observation.subscribe(directory.description) { [self] in
            // What moves when an entry is added, removed or renamed. A
            // server that reports neither for a folder reports nothing to
            // compare, and the poll then never hints; the listing on
            // appearance and the app's own operations still refresh it.
            let resource = try await propfind(directory, depth: "0", collection: true).first
            return "\(resource?.etag ?? "")|\(resource?.lastModified?.timeIntervalSince1970 ?? 0)"
        }
    }

    // MARK: - Pieces

    /// The directory's children, the directory itself left out.
    private func entries(in directory: ServicePath) async throws -> [FileEntry] {
        try await members(of: directory).children
    }

    /// One depth-1 `PROPFIND` of `directory`, split into the directory's own
    /// resource and its direct children.
    ///
    /// The folder itself is the response whose path is the one asked for.
    /// A server behind a proxy may answer under another prefix — Alist at
    /// `/alist/dav/` that still says `/dav/` — and then it is the response
    /// every other one sits under. A child is a response exactly one
    /// component below it; anything deeper, from a server that ignored the
    /// depth, is left out, and so is a child whose name is not one name —
    /// empty, `.`, `..`, or an encoded `/` — with a log line, rather than
    /// listed under a name that would address another file.
    func members(of directory: ServicePath) async throws -> (own: WebDAVResource?, children: [FileEntry], others: Int) {
        let resources = try await propfind(directory, depth: "1", collection: true)
        let requestURL = transport.url(for: directory.components, collection: true)
        let requested = (URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedPath)
            .flatMap(WebDAVResource.components(ofEncodedPath:)) ?? []
        let split = Self.split(resources, requested: requested)
        var children: [FileEntry] = []
        for (resource, name) in split.children {
            guard (try? directory.appending(name)) != nil else {
                FilaLog.warning("webdav: skipped an entry the server named \(name.debugDescription)")
                continue
            }
            children.append(entry(for: resource, name: name))
        }
        if split.skipped > 0 {
            FilaLog.warning("webdav: skipped \(split.skipped) entries outside \(directory)")
        }
        // Everything that is not the folder itself, listed or not: what a
        // removal must count before it calls the folder empty.
        let others = resources.count - (split.own == nil ? 0 : 1)
        return (split.own, children, others)
    }

    /// The pure half of `members`: which response is the folder, and which
    /// are its direct children under the server's own spelling of each name.
    static func split(
        _ resources: [WebDAVResource],
        requested: [String],
    ) -> (own: WebDAVResource?, children: [(WebDAVResource, String)], skipped: Int) {
        let parsed = resources.compactMap { resource in
            resource.components.map { (resource: resource, key: $0.map(comparable), names: $0) }
        }
        let requestedKey = requested.map(comparable)
        var ownKey = parsed.first { $0.key == requestedKey }?.key
        if ownKey == nil, let shortest = parsed.min(by: { $0.key.count < $1.key.count }) {
            if parsed.count == 1 {
                // An empty folder under another prefix: one response, which
                // is the folder only if it carries the folder's name.
                if shortest.key.last == requestedKey.last {
                    ownKey = shortest.key
                }
            } else if parsed.allSatisfy({ $0.key == shortest.key || ($0.key.count > shortest.key.count
                    && Array($0.key.prefix(shortest.key.count)) == shortest.key) }),
                parsed.filter({ $0.key == shortest.key }).count == 1 {
                // The one response every other sits strictly under.
                ownKey = shortest.key
            }
        }
        let base = ownKey ?? requestedKey
        var own: WebDAVResource?
        var children: [(WebDAVResource, String)] = []
        var skipped = 0
        for item in parsed {
            if item.key == base {
                own = item.resource
            } else if item.key.count == base.count + 1, Array(item.key.prefix(base.count)) == base, let name = item.names.last {
                children.append((item.resource, name))
            } else {
                skipped += 1
            }
        }
        return (own, children, skipped)
    }

    /// A component as compared for "is this the folder": precomposed, so a
    /// server that answers in NFD does not list the folder inside itself.
    private static func comparable(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping
    }

    func entry(for resource: WebDAVResource, name: String) -> FileEntry {
        FileEntry(
            name: name,
            kind: resource.isCollection ? .directory : .file,
            size: resource.isCollection ? nil : resource.contentLength,
            modified: resource.lastModified,
            isHidden: name.hasPrefix("."),
        )
    }

    func propfind(_ path: ServicePath, depth: String, collection: Bool) async throws -> [WebDAVResource] {
        var request = URLRequest(url: transport.url(for: path.components, collection: collection || path.isRoot))
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = WebDAVMultistatus.propfindBody
        let reply = try await send(request, path: path)
        switch reply.status {
        case 300 ..< 400 where !collection && !path.isRoot:
            // A folder asked for without its slash, by a server that
            // redirects rather than answers: ask again as a folder.
            return try await propfind(path, depth: depth, collection: true)
        case 207:
            return try WebDAVMultistatus.parse(reply.body)
        case 200 ..< 300, 405, 501:
            // A web page, or a server that does not know the method: the
            // address is not a WebDAV collection.
            throw WebDAVError.notWebDAV
        default:
            throw Self.refusal(reply, path: path)
        }
    }

    /// `request` on the transport, its failure as a `WebDAVError`. The
    /// caller's cancellation stays a cancellation.
    func send(
        _ request: URLRequest,
        path _: ServicePath,
        upload: WebDAVTransport.Upload? = nil,
        sink: WebDAVTransport.Sink = .collect,
    ) async throws -> WebDAVTransport.Reply {
        do {
            return try await transport.send(request, upload: upload, sink: sink)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebDAVError.map(error)
        }
    }

    /// The `WebDAVError` a refusal of a request on `path` means.
    static func refusal(_ reply: WebDAVTransport.Reply, path: ServicePath) -> WebDAVError {
        let shown = path.description
        switch reply.status {
        case 401: return .authenticationFailed
        case 403: return .accessDenied(path: shown)
        case 404, 410: return .notFound(path: shown)
        case 412: return .changedOnServer(path: shown)
        case 507: return .insufficientStorage
        case 300 ..< 400: return .notWebDAV
        default: return .server(status: reply.status, path: shown)
        }
    }

    /// True once: a listing is one reply, handed over by the first `next`.
    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { done = true }
            return !done
        }
    }
}
