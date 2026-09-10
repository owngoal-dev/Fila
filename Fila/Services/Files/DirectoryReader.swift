import FilaClient
import FilaLog
import FilaProtocol
import Foundation

/// Pull-based pages: the next backend request starts only when the consumer
/// asks for it. A slow UI never accumulates an unbounded queue of pages.
enum DirectoryReader {
    static let maximumEntryCount = 50000

    @MainActor
    static func pages(in path: String, session: FileSession) -> Pages {
        Pages(path: path, session: session, link: session.link)
    }

    struct Pages: AsyncSequence {
        typealias Element = [FileNode]
        let path: String
        let session: FileSession
        let link: any LocalFileAccess

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(path: path, session: session, link: link)
        }

        final class AsyncIterator: AsyncIteratorProtocol {
            let path: String
            let session: FileSession
            let link: any LocalFileAccess
            private var cursor: UInt64? = 0

            init(path: String, session: FileSession, link: any LocalFileAccess) {
                self.path = path
                self.session = session
                self.link = link
            }

            deinit {
                guard let cursor, cursor != 0 else { return }
                let link = link
                Task { try? await link.closeDirectory(cursor: cursor) }
            }

            func next() async throws -> [FileNode]? {
                try Task.checkCancellation()
                guard let cursor else { return nil }
                let path = path
                let page = try await session.perform(retryOnDisconnect: true) {
                    try Task.checkCancellation()
                    return try await $0.list(directory: path, cursor: cursor)
                }
                self.cursor = page.cursor == 0 ? nil : page.cursor
                try Task.checkCancellation()
                return page.entries
            }
        }
    }

    /// The browser's listing: the one place that says which way a directory
    /// is read.
    ///
    /// With the daemon, the app reads the directory itself over the
    /// descriptor the daemon opened as root — complete entries a few
    /// hundred at a time, one `open` round trip, no pages and no work in the
    /// daemon beyond the open and a `details` per link it may not follow
    /// (see `DirectoryBulkReader`). A directory this process may not search
    /// refuses the attributes before any entry, and the daemon's pages list
    /// it instead, the way they list everything for the in-process backend,
    /// which keeps its pages: it is already here. `hello` is nil while the
    /// handshake is still out, so a listing started then is paged too; the
    /// next reload takes the descriptor.
    ///
    /// The other listers — `entries`, `FileSearch`, the destination pickers,
    /// workspace cleanup — still read pages; moving them here is a change
    /// to what they need (complete nodes, no truncation) and is not made yet.
    @MainActor
    static func stream(in directory: String, session: FileSession) -> AsyncThrowingStream<[FileNode], Error> {
        guard session.hello?.isPrivileged == true else {
            let pages = pages(in: directory, session: session).makeAsyncIterator()
            return AsyncThrowingStream { try await pages.next() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var delivered = false
                do {
                    let descriptor = try await session.perform(retryOnDisconnect: true) {
                        try await $0.open(directory, flags: O_RDONLY | O_DIRECTORY)
                    }
                    let opened = DirectoryDescriptor(descriptor: descriptor)
                    let entries = DirectoryBulkReader.entries(in: opened, path: directory, limit: maximumEntryCount) { name in
                        // A link this process may not follow: the daemon can.
                        // An ask that fails — the link dropped, or the daemon
                        // gone between the open and now — reads as a link to
                        // nowhere, which is what the browser showed before
                        // the ask existed. The ask holds its batch, so it does
                        // not wait out a daemon that launchd is reloading the
                        // way the open above does; the next listing will.
                        let path = (directory as NSString).appendingPathComponent(name)
                        let details = try? await session.perform { try await $0.details(of: path) }
                        return details?.node.link?.resolvedKind
                    }
                    for try await batch in entries {
                        delivered = true
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    // Nothing has reached the consumer, so the daemon's pages
                    // can start from the top without repeating a row, and
                    // they list every directory this could not: the kernel
                    // refusing the attributes to this process (the descriptor
                    // was root's, the reads were not), a volume without a
                    // bulk read, a layout the reader does not know. What the
                    // pages refuse too — the daemon's own refusal of the open,
                    // a path that is not a directory — they surface, at the
                    // cost of one more round trip. A failure after the first
                    // batch is a real one and surfaces as one.
                    guard !delivered, !(error is CancellationError), !Task.isCancelled else {
                        continuation.finish(throwing: error)
                        return
                    }
                    let described = (error as? FilaFailure).map(FilaLog.describe) ?? String(describing: error)
                    FilaLog.verbose("list \(directory): \(described) reading here, listing through the daemon")
                    do {
                        for try await page in pages(in: directory, session: session) {
                            continuation.yield(page)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Consumers requiring a complete listing must fail rather than treating
    /// an incomplete result as all entries (especially workspace cleanup).
    static func entries(in path: String, session: FileSession, limit: Int = maximumEntryCount) async throws -> [FileNode] {
        var entries: [FileNode] = []
        for try await page in await pages(in: path, session: session) {
            guard page.count <= limit - entries.count else { throw FilaFailure(errno: E2BIG, path: path) }
            entries.append(contentsOf: page)
        }
        return entries
    }
}
