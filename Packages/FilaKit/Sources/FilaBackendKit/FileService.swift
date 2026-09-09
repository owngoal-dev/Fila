import Foundation

/// A path relative to a file service's root: validated components, nothing
/// else.
///
/// Lexical composition is shared here; what a component means on disk or on
/// the wire belongs to the backend that resolves it. The validation is what
/// makes a location safe to store and to hand across backends: no component
/// is empty, names itself or its parent, or contains a separator or NUL, so
/// a path can never step out of the root it is relative to.
public struct ServicePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public static let root = ServicePath()

    private init() {
        components = []
    }

    public init(components: [String]) throws {
        for component in components {
            try ServicePath.validate(component)
        }
        self.components = components
    }

    /// Splits `string` on `/`. Leading and trailing separators are ignored,
    /// so "/a/b/" and "a/b" are the same path; an empty component elsewhere
    /// is not.
    public init(_ string: String) throws {
        var pieces = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.first == "" { pieces.removeFirst() }
        if pieces.last == "" { pieces.removeLast() }
        try self.init(components: pieces)
    }

    public var isRoot: Bool { components.isEmpty }
    public var name: String? { components.last }
    public var parent: ServicePath? {
        guard !isRoot else { return nil }
        return ServicePath(unchecked: Array(components.dropLast()))
    }

    public func appending(_ component: String) throws -> ServicePath {
        try ServicePath.validate(component)
        return ServicePath(unchecked: components + [component])
    }

    public func appending(_ path: ServicePath) -> ServicePath {
        ServicePath(unchecked: components + path.components)
    }

    /// The path joined with `/`, without a leading separator; empty at the
    /// root. For display and for backends whose wire form is a POSIX path.
    public var description: String { components.joined(separator: "/") }

    private init(unchecked components: [String]) {
        self.components = components
    }

    private static func validate(_ component: String) throws {
        guard !component.isEmpty else { throw ServicePathError.emptyComponent }
        guard component != ".", component != ".." else { throw ServicePathError.relativeComponent(component) }
        guard !component.contains("/") else { throw ServicePathError.separatorInComponent(component) }
        guard !component.utf8.contains(0) else { throw ServicePathError.nulInComponent }
    }

    // Codable through the joined string keeps a stored bookmark readable.
    public init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum ServicePathError: Error, Equatable, CustomStringConvertible {
    case emptyComponent
    case relativeComponent(String)
    case separatorInComponent(String)
    case nulInComponent

    public var description: String {
        switch self {
        case .emptyComponent: return "empty path component"
        case let .relativeComponent(name): return "path component \"\(name)\" is not a name"
        case let .separatorInComponent(name): return "path component \"\(name)\" contains a separator"
        case .nulInComponent: return "path component contains NUL"
        }
    }
}

/// A file service's location: which backend, and where under its root.
/// Identical paths on different backends are different locations.
public struct FileLocation: Hashable, Sendable, Codable {
    public let backend: BackendID
    public let path: ServicePath

    public init(backend: BackendID, path: ServicePath) {
        self.backend = backend
        self.path = path
    }
}

/// One directory entry as every backend can describe it.
///
/// Unknown remote metadata stays optional; nothing here fabricates an inode,
/// an owner, a mode or an epoch date for a server that did not send one.
public struct FileEntry: Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        /// A link, and what it points at when the backend could tell.
        case symbolicLink(resolved: ResolvedKind?)
        /// Something that is neither: a device, a socket, a fifo.
        case other

        public enum ResolvedKind: Sendable, Hashable {
            case file, directory, other
        }
    }

    public let name: String
    public let kind: Kind
    public let size: Int64?
    public let modified: Date?
    public let isHidden: Bool

    public init(name: String, kind: Kind, size: Int64?, modified: Date?, isHidden: Bool) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
    }

    /// Whether navigating into this entry lists a directory. A link is
    /// entered only when the backend resolved it to one; that says nothing
    /// about whether a mutation may treat it as a directory.
    public var entersDirectory: Bool {
        switch kind {
        case .directory: return true
        case .symbolicLink(resolved: .directory): return true
        default: return false
        }
    }
}

/// Bytes moved so far, and how many were expected when that is known. An
/// unknown length is never a made-up percentage.
public struct TransferProgress: Sendable, Equatable {
    public let completed: Int64
    public let expected: Int64?

    public init(completed: Int64, expected: Int64?) {
        self.completed = completed
        self.expected = expected
    }
}

/// A directory's entries, pulled one batch at a time.
///
/// Every iterator opens its own source: the adapter's cursor or handle
/// belongs to that iteration alone, the next batch is fetched only when the
/// consumer asks, and the source is released on completion, on an error
/// and on cancellation — a consumer that stops iterating early cancels its
/// task, and `close` runs then. A batch is what the backend had ready: a
/// local page, a remote response. Reaching the consumer's own entry limit
/// is the consumer's to report; a listing never pretends a partial result
/// is complete.
public struct FileListing: AsyncSequence, Sendable {
    public typealias Element = [FileEntry]

    /// One iteration's producer. `next` returns nil once the directory is
    /// exhausted; `close` releases whatever `next` holds and is called
    /// exactly once, on any exit.
    public struct Source: Sendable {
        public let next: @Sendable () async throws -> [FileEntry]?
        public let close: @Sendable () async -> Void

        public init(
            next: @escaping @Sendable () async throws -> [FileEntry]?,
            close: @escaping @Sendable () async -> Void
        ) {
            self.next = next
            self.close = close
        }
    }

    private let open: @Sendable () -> Source

    /// `open` runs once per iterator and must hand back fresh state each
    /// time; two iterations of one listing never share a cursor.
    public init(open: @escaping @Sendable () -> Source) {
        self.open = open
    }

    /// A listing that was complete when it was made: what a catalogue
    /// backend hands back, in one batch.
    public init(entries: [FileEntry]) {
        self.init {
            let box = ConsumedOnce(entries)
            return Source(next: { box.take() }, close: {})
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(source: open())
    }

    public final class Iterator: AsyncIteratorProtocol, @unchecked Sendable {
        private let source: Source
        private var finished = false

        init(source: Source) {
            self.source = source
        }

        public func next() async throws -> [FileEntry]? {
            guard !finished else { return nil }
            do {
                try Task.checkCancellation()
                if let batch = try await source.next() {
                    return batch
                }
                await finish()
                return nil
            } catch {
                await finish()
                throw error
            }
        }

        private func finish() async {
            guard !finished else { return }
            finished = true
            await source.close()
        }

        deinit {
            // An iterator dropped mid-listing — a consumer that stopped
            // without cancelling — still releases the directory.
            guard !finished else { return }
            let release = source.close
            Task { await release() }
        }
    }

    private final class ConsumedOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [FileEntry]?
        init(_ entries: [FileEntry]) { self.entries = entries }
        func take() -> [FileEntry]? {
            lock.lock(); defer { lock.unlock() }
            defer { entries = nil }
            return entries
        }
    }
}

/// The I/O contract every file backend answers: list, describe, and hand
/// over a file's bytes.
///
/// Each instance is bound to one root — a local directory, an SMB share, an
/// FTP starting directory — and every path is relative to it. Consumers
/// resolve an instance once and never switch on the protocol behind it.
/// Descriptors, POSIX attributes, mount points and jobs are not here: they
/// are local, and local consumers keep the local contract for them.
public protocol FileService: AnyObject, Sendable {
    func list(_ directory: ServicePath) async throws -> FileListing
    func details(_ path: ServicePath) async throws -> FileEntry

    /// Copies the file at `path` into `descriptor`, a writable descriptor
    /// the caller opened on a new, empty, private staging file and keeps
    /// open until this returns. The service writes bounded chunks, handles
    /// short writes, neither closes the descriptor nor publishes anything,
    /// and has stopped touching it by the time this returns or throws —
    /// including on cancellation. The caller discards an incomplete staging
    /// file.
    func copyContents(
        of path: ServicePath,
        to descriptor: Int32,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws

    /// Invalidation hints for one directory: each element means "list it
    /// again", nothing more. Observation is installed before this returns
    /// and the first element arrives at once, so a consumer that awaits an
    /// element before every listing never has a list-then-subscribe gap.
    /// Every call is an independent subscription buffering the newest hint;
    /// bursts coalesce. Cancelling the consuming task removes the
    /// subscriber, and the last subscriber releases whatever watched the
    /// directory. A lost connection ends the stream with an error.
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error>
}

/// A backend whose root is a filesystem: what the file browser, bookmarks
/// and transfers work on. Catalogue backends do not conform.
@MainActor
public protocol FileBackend: Backend {
    /// The I/O session for this root. Owns lazy connection and reconnection;
    /// a backend's sidebar data does not require it.
    func fileService() async throws -> any FileService

    /// Bookmarks and history are the backend's, persisted through its own
    /// storage and reflected in its next sidebar snapshot. `recordVisit` is
    /// called after a directory was opened for the user, never by
    /// background enumeration; it does nothing while visits are not being
    /// recorded.
    func setFavorite(_ path: ServicePath, included: Bool) throws
    func recordVisit(_ path: ServicePath) throws
    func forgetVisit(_ path: ServicePath) throws

    /// The app's one history policy, applied to every backend. Turning it
    /// off clears what this backend already recorded.
    func setRecordsVisits(_ enabled: Bool) throws

    /// No directory polling while the app is not on screen; resuming
    /// hints every open browser once, because anything may have happened.
    /// The shell calls this on every file backend when it backgrounds.
    func setObservationPaused(_ paused: Bool)
}
