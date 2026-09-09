import FilaClient
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
