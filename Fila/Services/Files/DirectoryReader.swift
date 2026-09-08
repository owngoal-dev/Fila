import FilaProtocol
import Foundation

/// Pull-based pages: the next backend request starts only when the consumer
/// asks for it. A slow UI never accumulates an unbounded queue of pages.
enum DirectoryReader {
    static let maximumEntryCount = 50000

    @MainActor
    static func pages(in path: String, session: FileSession) -> Pages {
        Pages(path: path, session: session)
    }

    struct Pages: AsyncSequence {
        typealias Element = [FileNode]
        let path: String
        let session: FileSession

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(path: path, session: session)
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            let path: String
            let session: FileSession
            private var cursor: UInt64? = 0

            init(path: String, session: FileSession) {
                self.path = path
                self.session = session
            }

            mutating func next() async throws -> [FileNode]? {
                try Task.checkCancellation()
                guard let cursor else { return nil }
                let path = path
                let page = try await session.perform(retryOnDisconnect: true) {
                    try await $0.list(directory: path, cursor: cursor)
                }
                try Task.checkCancellation()
                self.cursor = page.cursor == 0 ? nil : page.cursor
                return page.entries
            }
        }
    }

    /// Consumers requiring a complete listing must fail rather than treating
    /// an incomplete result as all entries (especially workspace cleanup).
    @MainActor
    static func entries(in path: String, session: FileSession) async throws -> [FileNode] {
        var entries: [FileNode] = []
        for try await page in pages(in: path, session: session) {
            guard page.count <= maximumEntryCount - entries.count else { throw FilaFailure(errno: E2BIG, path: path) }
            entries.append(contentsOf: page)
        }
        return entries
    }
}
