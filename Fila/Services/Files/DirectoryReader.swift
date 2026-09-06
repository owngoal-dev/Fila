import FilaProtocol
import Foundation

/// A directory as it arrives, one page at a time.
///
/// The whole point of paging is that nothing ever holds a whole directory: a
/// listing of 100k entries is 196 messages, and the browser shows the first one
/// while the rest are still coming. A caller that abandons a listing simply
/// cancels the task — the daemon closes the handle it kept open after
/// `FilaProtocol.listingIdleTimeoutSeconds`, so there is nothing to tell it.
enum DirectoryReader {
    @MainActor
    static func pages(in path: String, session: FileSession) -> AsyncThrowingStream<[FileNode], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var cursor: UInt64 = 0
                    repeat {
                        let page = try await session.perform(retryOnDisconnect: true) {
                            try await $0.list(directory: path, cursor: cursor)
                        }
                        if Task.isCancelled { break }
                        continuation.yield(page.entries)
                        cursor = page.cursor
                    } while cursor != 0
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every entry, for the callers that genuinely need the whole thing — the
    /// archive walk and the app-container scan. Never use this to fill a list.
    @MainActor
    static func entries(in path: String, session: FileSession) async throws -> [FileNode] {
        var entries: [FileNode] = []
        for try await page in pages(in: path, session: session) {
            entries.append(contentsOf: page)
        }
        return entries
    }
}
