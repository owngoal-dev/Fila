#if canImport(XPC)
import Foundation
import Testing
import XPC

@testable import FilaProtocol

// The one message type the daemon sends that nothing else round-trips. Both
// ends compile `XPCCoding`, so a field cannot go missing on one side — but a
// key can be spelled twice, and then a match arrives with somebody else's name
// in it.

@Suite("Search on the wire")
struct SearchWireTests {
    private func node(named name: String) -> FileNode {
        FileNode(
            name: name,
            kind: .symbolicLink,
            size: 11,
            allocatedSize: 4_096,
            modified: 1,
            created: 2,
            accessed: 3,
            mode: 0o120_755,
            ownerID: 501,
            groupID: 20,
            systemFlags: UInt32(UF_HIDDEN),
            linkCount: 1,
            inode: 42,
            link: SymbolicLink(target: "../elsewhere", resolvedKind: .directory)
        )
    }

    @Test("A batch of matches survives the round trip, limits and all")
    func batchRoundTrip() throws {
        let batch = SearchBatch(
            matches: [
                SearchMatch(directory: "/private/var/mobile", node: node(named: "Library")),
                SearchMatch(directory: "/", node: node(named: "var")),
            ],
            limits: [.resultCount, .unreadable]
        )

        let decoded = try #require(SearchBatch.decode(batch.encoded(jobIdentifier: 7)))
        #expect(decoded.jobIdentifier == 7)
        #expect(decoded.batch == batch)
        // The one thing a match carries that a `FileNode` cannot.
        #expect(decoded.batch.matches.first?.path == "/private/var/mobile/Library")
        #expect(decoded.batch.matches.last?.path == "/var")
    }

    @Test("A search result and a job event are not mistaken for one another")
    func theTwoMessagesAreDistinct() {
        let result = SearchBatch(matches: [], limits: .depth).encoded(jobIdentifier: 1)
        let event = JobEvent.completed(FilaFailure(code: .success)).encoded(jobIdentifier: 1)

        #expect(JobEvent.decode(result) == nil)
        #expect(SearchBatch.decode(event) == nil)
        #expect(SearchBatch.decode(result)?.batch.limits == .depth)
    }

    @Test("A query rides along with the job that needs it, and only that one")
    func queryRidesWithTheRequest() throws {
        let request = JobRequest(
            kind: .search,
            sources: ["/private/var"],
            query: SearchQuery(text: "*.plist", isCaseSensitive: true, includesHidden: true, isGlob: true)
        )
        let message = xpc_dictionary_create(nil, nil, 0)
        request.encode(into: message)
        #expect(JobRequest(decoding: message) == request)

        // Every other kind carries none, and decoding must not invent one.
        let plain = JobRequest(kind: .delete, sources: ["/tmp/x"], useTrash: true)
        let other = xpc_dictionary_create(nil, nil, 0)
        plain.encode(into: other)
        #expect(JobRequest(decoding: other)?.query == nil)
    }
}
#endif
