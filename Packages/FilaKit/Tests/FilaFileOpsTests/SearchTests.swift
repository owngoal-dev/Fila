import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

// A whole-device search against a real tree on a real filesystem. Every
// property under test here — `d_type` instead of `stat`, not following a link,
// stopping between entries — is a property of the syscalls, and a mock would
// have exactly the behaviour the test assumed rather than the one Darwin has.

@Suite("Search")
struct SearchTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    /// Everything one search reported, flattened the way a client's list is.
    struct Found {
        var matches: [SearchMatch]
        /// The last batch's limits. They are sticky and a final batch always
        /// goes out, so the last word is the whole word.
        var limits: SearchLimits
        var outcome: FilaFailure

        var names: [String] {
            matches.map(\.node.name).sorted()
        }
    }

    private func search(_ query: SearchQuery, in roots: [String]? = nil) -> Found {
        let job = FileJob(
            request: JobRequest(kind: .search, sources: roots ?? [scratch.root], query: query),
            operations: operations
        )
        var matches: [SearchMatch] = []
        var limits: SearchLimits = []
        let outcome = job.run(report: { _ in }) { batch in
            #expect(batch.matches.count <= FilaProtocol.searchBatchMatchCount)
            matches.append(contentsOf: batch.matches)
            limits = batch.limits
        }
        return Found(matches: matches, limits: limits, outcome: outcome)
    }

    // MARK: - Finding things

    @Test("A match several levels down is found, with the directory it was in")
    func findsADeepMatch() {
        scratch.directory("a/b/c/d/e")
        scratch.file("a/b/c/d/e/needle.plist", contents: "payload")
        scratch.file("a/b/decoy.txt")

        let found = search(SearchQuery(text: "needle"))
        #expect(found.outcome.code == .success)
        #expect(found.limits == [])
        #expect(found.matches.count == 1)
        #expect(found.matches.first?.path == scratch.path("a/b/c/d/e/needle.plist"))
        #expect(found.matches.first?.directory == scratch.path("a/b/c/d/e"))
        // The stat that only a match pays for: a result row shows these.
        #expect(found.matches.first?.node.kind == .regular)
        #expect(found.matches.first?.node.size == 7)
    }

    @Test("Every root given is searched, and the cap spans all of them")
    func searchesEveryRoot() {
        scratch.directory("left")
        scratch.directory("right")
        scratch.file("left/needle.txt")
        scratch.file("right/needle.txt")
        scratch.file("needle.txt")

        let found = search(
            SearchQuery(text: "needle"),
            in: [scratch.path("left"), scratch.path("right")]
        )
        #expect(found.outcome.code == .success)
        #expect(found.names == ["needle.txt", "needle.txt"])
    }

    @Test("A root that cannot be opened fails the search — the user named it")
    func aBadRootIsAnError() {
        let found = search(SearchQuery(text: "needle"), in: [scratch.path("nowhere")])
        #expect(found.outcome.code == .notFound)
    }

    @Test("An empty query is refused rather than matching everything")
    func anEmptyQueryIsRefused() {
        scratch.file("anything.txt")
        #expect(search(SearchQuery(text: "")).outcome.code == .invalidRequest)
    }

    // MARK: - The query

    @Test("Case folding is the default, and the switch turns it off")
    func caseSensitivityBothWays() {
        scratch.file("Info.plist")
        scratch.file("info.txt")

        #expect(search(SearchQuery(text: "info")).names == ["Info.plist", "info.txt"])
        #expect(search(SearchQuery(text: "info", isCaseSensitive: true)).names == ["info.txt"])
        #expect(search(SearchQuery(text: "Info", isCaseSensitive: true)).names == ["Info.plist"])
    }

    @Test("A substring matches anywhere in the name, a glob matches all of it")
    func globAndSubstring() {
        scratch.file("Info.plist")
        scratch.file("plist.txt")

        #expect(search(SearchQuery(text: "plist")).names == ["Info.plist", "plist.txt"])
        #expect(search(SearchQuery(text: "*.plist", isGlob: true)).names == ["Info.plist"])
        // A glob folds case by the same switch the substring does.
        #expect(search(SearchQuery(text: "*.PLIST", isGlob: true)).names == ["Info.plist"])
        #expect(search(SearchQuery(text: "*.PLIST", isCaseSensitive: true, isGlob: true)).names == [])
    }

    @Test("Hidden entries are matched and walked into only when asked for")
    func hiddenEntriesAreOptional() {
        scratch.directory(".config/deep")
        scratch.file(".config/deep/token.txt")
        scratch.file(".token.txt")
        scratch.file("token.txt")

        // Not just the dotfile: a search that excluded hidden files but still
        // walked into `.config` would not be what the switch says.
        #expect(search(SearchQuery(text: "token")).names == ["token.txt"])
        #expect(search(SearchQuery(text: "token", includesHidden: true)).names
            == [".token.txt", "token.txt", "token.txt"])
    }

    // MARK: - What the walk refuses to do

    @Test("A symlink loop that would hang a following walk does not")
    func doesNotFollowSymlinks() {
        scratch.directory("tree/inner")
        scratch.file("tree/inner/needle.txt")
        // Two loops a following walk would never come back from: one at its own
        // grandparent, one at the root of the whole search.
        scratch.link("tree/inner/loop", to: scratch.path("tree"))
        scratch.link("tree/self", to: scratch.root)
        scratch.link("tree/needle.lnk", to: "inner/needle.txt")

        let found = search(SearchQuery(text: "needle"))
        #expect(found.outcome.code == .success)
        // No depth limit hit, which is what a loop would have produced.
        #expect(found.limits == [])
        #expect(found.names == ["needle.lnk", "needle.txt"])

        // A link that matched by name is reported as the link, not as what it
        // points at: the walk stats with AT_SYMLINK_NOFOLLOW like everything
        // else here.
        let link = found.matches.first { $0.node.kind == .symbolicLink }
        #expect(link?.node.link?.target == "inner/needle.txt")
        #expect(link?.node.link?.resolvedKind == .regular)
    }

    @Test(
        "A directory the walk cannot read is skipped and reported, not fatal",
        .enabled(if: getuid() != 0, "root can read a mode-000 directory")
    )
    func anUnreadableDirectoryIsSkipped() {
        scratch.directory("open")
        scratch.file("open/needle.txt")
        let closed = scratch.directory("closed")
        scratch.file("closed/needle.txt")
        #expect(chmod(closed, 0) == 0)
        // Put it back, or the scratch directory cannot be torn down.
        defer { chmod(closed, 0o755) }

        let found = search(SearchQuery(text: "needle"))
        #expect(found.outcome.code == .success)
        #expect(found.names == ["needle.txt"])
        #expect(found.limits == .unreadable)
    }

    @Test("A branch deeper than the limit is left unwalked and said so")
    func theDepthLimitIsReported() {
        scratch.file("shallow-needle.txt")
        var relative = "deep"
        for _ in 0 ..< FilaProtocol.searchDepthLimit {
            relative += "/deep"
        }
        scratch.directory(relative)
        scratch.file(relative + "/deep-needle.txt")

        let found = search(SearchQuery(text: "needle"))
        #expect(found.outcome.code == .success)
        // Everything above the limit was still searched. Truncating in silence
        // is what this reports instead of.
        #expect(found.names == ["shallow-needle.txt"])
        #expect(found.limits == .depth)
    }

    // MARK: - Limits and cancellation

    @Test("The result cap is reported, not applied in silence")
    func theResultCapIsReported() {
        scratch.directory("full")
        for index in 0 ..< FilaProtocol.searchResultLimit + 10 {
            scratch.file("full/hit-\(index)")
        }

        // A second root that is not there. Once the cap is reached the walk
        // must not open it: a full list has to arrive as a full list, not as
        // the `.notFound` of a root it never needed to look at.
        let found = search(SearchQuery(text: "hit-"), in: [scratch.path("full"), scratch.path("nowhere")])
        #expect(found.outcome.code == .success)
        #expect(found.matches.count == FilaProtocol.searchResultLimit)
        #expect(found.limits == .resultCount)
    }

    @Test("Cancelling stops the walk between entries, not between directories")
    func cancellationStopsTheWalkMidDirectory() {
        // One wide directory and nothing else: a walk that only looked at
        // cancellation on its way into a directory would have to read all
        // 2,000 entries before it noticed.
        for index in 0 ..< 2000 {
            scratch.file("entry-\(index).txt")
        }

        let job = FileJob(
            request: JobRequest(kind: .search, sources: [scratch.root], query: SearchQuery(text: "entry-")),
            operations: operations
        )
        var matches: [SearchMatch] = []
        let outcome = job.run(report: { _ in }) { batch in
            matches.append(contentsOf: batch.matches)
            if !matches.isEmpty {
                job.cancel()
            }
        }

        #expect(outcome.code == .cancelled)
        // The matches found before the stop are still delivered — a cancelled
        // search shows what it had, it does not throw it away.
        #expect(!matches.isEmpty)
        #expect(matches.count < 2000)
    }

    @Test("Progress counts the entries looked at and names the directory")
    func progressCountsEntries() {
        scratch.directory("folder")
        for index in 0 ..< 200 {
            scratch.file("folder/entry-\(index).txt")
        }

        var last = JobProgress(bytesDone: 0, bytesTotal: 0, itemsDone: 0, itemsTotal: 0, currentPath: "")
        _ = FileJob(
            request: JobRequest(kind: .search, sources: [scratch.root], query: SearchQuery(text: "nothing-here")),
            operations: operations
        ).run { last = $0 }

        // 200 files plus the directory holding them. Bytes stay zero: a search
        // moves none, and `fraction` must stay nil so the app shows a spinner.
        #expect(last.itemsDone == 201)
        #expect(last.bytesDone == 0)
        #expect(last.fraction == nil)
        #expect(last.currentPath.hasPrefix(scratch.root))
    }
}
