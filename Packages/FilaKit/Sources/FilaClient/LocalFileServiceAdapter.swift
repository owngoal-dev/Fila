import Darwin
import FilaBackendKit
import FilaProtocol
import Foundation

/// The local file layer seen through the backend-neutral contract.
///
/// Paths are composed lexically under `rootPath`; every call then goes
/// through `LocalFileAccess`, so the guard, the canonicalisation and the
/// descriptor rules are the ones the daemon and the in-process service
/// already enforce. Nothing here opens a file by itself.
final class LocalFileServiceAdapter: FileService, @unchecked Sendable {
    private let access: any LocalFileAccess
    private let rootPath: String

    /// Bytes per `read(2)`/`write(2)` in `copyContents`. Large enough that a
    /// multi-gigabyte copy is not a syscall storm, small enough that
    /// cancellation is answered promptly and the buffer is not worth noticing.
    static let chunkSize = 1 << 20

    init(access: any LocalFileAccess, rootPath: String) {
        self.access = access
        self.rootPath = rootPath
    }

    func absolutePath(_ path: ServicePath) -> String {
        guard !path.isRoot else { return rootPath }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + path.components.joined(separator: "/")
    }

    func list(_ directory: ServicePath) async throws -> FileListing {
        let access = access
        let path = absolutePath(directory)
        return FileListing {
            let cursor = ListingCursor()
            return FileListing.Source(
                next: {
                    // Finished last time: the directory is already closed.
                    guard let current = cursor.next else { return nil }
                    let page = try await access.list(directory: path, cursor: current)
                    cursor.next = page.isFinal ? nil : page.cursor
                    return page.entries.map(FileEntry.init(node:))
                },
                close: {
                    // Only a listing abandoned between pages holds a cursor:
                    // a finished one released it with its last page, and one
                    // that never asked for a page has nothing to release.
                    guard let open = cursor.takeOpen() else { return }
                    try? await access.closeDirectory(cursor: open)
                }
            )
        }
    }

    func details(_ path: ServicePath) async throws -> FileEntry {
        FileEntry(node: try await access.details(of: absolutePath(path)).node)
    }

    func copyContents(
        of path: ServicePath,
        to descriptor: Int32,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let source = absolutePath(path)
        let input = try await access.open(source, flags: O_RDONLY)
        defer { close(input) }
        // What was opened, not what was named: `open` follows a symlink and
        // adds `O_NONBLOCK`, so a device or a fifo would come back as a
        // descriptor that never reaches end of file or reads `EAGAIN`. Only a
        // regular file has contents to copy, and its size is the honest
        // expectation — `details` would have measured the link.
        var status = stat()
        guard fstat(input, &status) == 0 else { throw FilaFailure(errno: errno, path: source) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw FilaFailure(errno: status.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL, path: source)
        }
        let expected = Int64(status.st_size)
        // The pump blocks in `read`/`write`, so it runs on a plain queue
        // rather than the cooperative pool — and a detached task would not
        // see the caller's cancellation, so that travels through a flag the
        // handler sets and every chunk checks.
        let cancelled = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                LocalFileServiceAdapter.copyQueue.async {
                    continuation.resume(with: Result {
                        try LocalFileServiceAdapter.pump(
                            from: input, to: descriptor, expected: expected,
                            isCancelled: { cancelled.isSet }, progress: progress
                        )
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private static let copyQueue = DispatchQueue(
        label: "wiki.qaq.fila.local.copy", qos: .userInitiated, attributes: .concurrent
    )

    /// Blocking: runs off the cooperative pool.
    private static func pump(
        from input: Int32,
        to output: Int32,
        expected: Int64,
        isCancelled: () -> Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) throws {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var completed: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw FilaFailure(errno: errno)
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                if isCancelled() { throw CancellationError() }
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw FilaFailure(errno: errno)
                }
                // A write that moved nothing would loop here forever.
                guard wrote > 0 else { throw FilaFailure(errno: EIO) }
                written += wrote
            }
            completed += Int64(count)
            progress(TransferProgress(completed: completed, expected: expected))
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// One iteration's place in a directory: zero before the first page,
    /// the daemon's cursor between pages, nil once finished or released.
    private final class ListingCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64? = 0
        var next: UInt64? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }

        /// The cursor to close, if there is one, marking it released in the
        /// same step so a second release finds nothing.
        func takeOpen() -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            defer { value = nil }
            guard let open = value, open != 0 else { return nil }
            return open
        }
    }
}

extension FileEntry {
    /// A local node, with only what the neutral contract can promise about
    /// it. The full node stays available to local consumers.
    init(node: FileNode) {
        let kind: Kind
        switch node.kind {
        case .regular: kind = .file
        case .directory: kind = .directory
        case .symbolicLink:
            let resolved: Kind.ResolvedKind? = node.link?.resolvedKind.map { target in
                switch target {
                case .regular: return .file
                case .directory: return .directory
                default: return .other
                }
            }
            kind = .symbolicLink(resolved: resolved)
        default: kind = .other
        }
        self.init(
            name: node.name,
            kind: kind,
            size: node.kind == .regular ? node.size : nil,
            modified: Date(timeIntervalSince1970: node.modified),
            isHidden: node.isHidden
        )
    }
}
