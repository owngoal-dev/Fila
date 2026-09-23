import FilaProtocol
import Foundation

/// What a folder holds, counted from the app the way `FileSearch` walks it.
///
/// The daemon is never asked to walk a tree (6 MB; see `FileSearch`), so the
/// frontier is here and every folder is read page by page. Links are not
/// followed — what a link points to belongs to somewhere else, and following
/// the links of a jailbroken filesystem counts `/private` several times over.
enum FolderSize {
    struct Totals: Equatable {
        /// Bytes of every file and link below the folder. A directory's own
        /// `st_size` is an artefact of the filesystem, not content, and is
        /// left out, which is what Finder shows too.
        var size: Int64 = 0
        /// Blocks in use by everything below it, directories included.
        var allocatedSize: Int64 = 0
        /// Files, folders and links below it, the folder itself not counted.
        var items = 0
        /// Folders that could not be listed; what is inside them is missing
        /// from the totals.
        var unreadableFolders = 0
    }

    /// Hands the running totals to `onProgress` at most every `interval`, and
    /// returns the final ones — or nil once the task is cancelled, which is
    /// what leaving the screen does.
    @MainActor
    static func count(
        _ root: String,
        session: FileSession,
        interval: TimeInterval = 0.25,
        onProgress: @MainActor (Totals) -> Void
    ) async -> Totals? {
        var totals = Totals()
        var frontier = [root]
        var next = 0
        // A file with several names is counted once, the way `du` does:
        // the blocks are shared, and adding them twice would promise space
        // that deleting the folder never gives back.
        var linkedInodes: Set<UInt64> = []
        var reportedAt = Date()
        while next < frontier.count {
            let directory = frontier[next]
            frontier[next] = ""
            next += 1
            // Pages of a live directory can repeat a name; see `FileSearch`.
            var seen: Set<String> = []
            do {
                for try await page in DirectoryReader.pages(in: directory, session: session) {
                    for node in page where seen.insert(node.name).inserted {
                        totals.items += 1
                        if node.kind == .directory {
                            totals.allocatedSize += node.allocatedSize
                            frontier.append(directory == "/" ? "/" + node.name : directory + "/" + node.name)
                            continue
                        }
                        if node.linkCount > 1, !linkedInodes.insert(node.inode).inserted {
                            continue
                        }
                        totals.size += node.size
                        totals.allocatedSize += node.allocatedSize
                    }
                    if Date().timeIntervalSince(reportedAt) >= interval {
                        reportedAt = Date()
                        onProgress(totals)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                totals.unreadableFolders += 1
            }
            guard !Task.isCancelled else { return nil }
        }
        return totals
    }
}
