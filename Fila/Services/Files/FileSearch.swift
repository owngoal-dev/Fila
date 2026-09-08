import FilaProtocol
import Foundation

/// One hit, with the directory it was found in — a `FileNode` deliberately
/// carries no path, so the walk has to remember where it was.
struct FileSearchResult: Hashable {
    var directory: String
    var node: FileNode

    var path: String {
        directory == "/" ? "/" + node.name : directory + "/" + node.name
    }
}

/// A recursive search, driven from the app.
///
/// The daemon is never asked to walk a tree. A walk holds a frontier that grows
/// with the filesystem, and the daemon is capped at 6 MB by jetsam — the whole
/// reason listings are paged in the first place. Here the frontier is in the
/// app, where a few thousand paths cost nothing, and the caps below stop a
/// search of `/` from running until the user gives up on it.
enum FileSearch {
    static let depthLimit = 8
    static let resultLimit = 100

    /// Breadth-first so shallow hits — the ones the user usually meant — arrive
    /// first. Streams matches as it goes and stops the moment the task is
    /// cancelled, which is what leaving the screen does.
    ///
    /// `onVisit` is handed each directory as the walk reaches it. A search of
    /// `/` touches hundreds of thousands of entries and can find nothing for a
    /// long time, and a screen that cannot say where it has got to is
    /// indistinguishable from one that has stopped.
    ///
    /// Returns how many links to directories were passed over without being
    /// entered, so the screen can say that what lies behind them was not
    /// searched.
    @MainActor
    @discardableResult
    static func run(
        root: String,
        needle: String,
        session: FileSession,
        onVisit: @MainActor (String) -> Void,
        onHit: @MainActor (FileSearchResult) -> Void
    ) async -> Int {
        let needle = needle.lowercased()
        guard !needle.isEmpty else { return 0 }
        var frontier = [(path: root, depth: 0)]
        var found = 0
        var skippedLinks = 0
        // A directory being listed is live, so a name can come back on two
        // pages, and a name queued twice would walk its whole subtree twice.
        // Emitting the same path twice is worse than wasteful: the results list
        // is a diffable snapshot, and two equal items in one is a crash.
        var visited: Set<String> = [root]
        var emitted: Set<String> = []

        while !frontier.isEmpty, found < resultLimit {
            let (directory, depth) = frontier.removeFirst()
            guard !Task.isCancelled else { return skippedLinks }
            onVisit(directory)
            guard let entries = try? await DirectoryReader.entries(in: directory, session: session) else { continue }
            for node in entries {
                guard !Task.isCancelled else { return skippedLinks }
                let path = directory == "/" ? "/" + node.name : directory + "/" + node.name
                if node.name.lowercased().contains(needle), emitted.insert(path).inserted {
                    onHit(FileSearchResult(directory: directory, node: node))
                    found += 1
                    if found >= resultLimit {
                        return skippedLinks
                    }
                }
                // Symlinks are not followed: a jailbroken filesystem is full of
                // links back into `/private`, and a walk that follows them
                // visits the same subtree several times and can loop forever.
                // The link's own name is still matched above; only what lies
                // behind it is skipped, and that is counted so the screen can
                // say so.
                if node.kind == .directory, depth < depthLimit, visited.insert(path).inserted {
                    frontier.append((path, depth + 1))
                } else if node.kind == .symbolicLink, node.link?.resolvedKind == .directory {
                    skippedLinks += 1
                }
            }
        }
        return skippedLinks
    }
}
