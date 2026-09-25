import FilaFileOps
import Foundation
import Testing

@Suite("Shared Inbox")
struct SharedInboxTests {
    @Test
    func `Imports preserve existing names and source bytes`() throws {
        let scratch = Scratch()
        let group = URL(fileURLWithPath: scratch.directory("group"))
        let source = URL(fileURLWithPath: scratch.path("example.txt"))
        try Data("first".utf8).write(to: source)
        let inbox = try SharedInbox.directory(in: group)
        try SharedInbox.save(source, suggestedName: "example.txt", in: inbox)
        try Data("second".utf8).write(to: source)
        try SharedInbox.save(source, suggestedName: "example.txt", in: inbox)
        #expect(try String(contentsOf: inbox.appendingPathComponent("example.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: inbox.appendingPathComponent("example (1).txt"), encoding: .utf8) == "second")
        #expect(try String(contentsOf: source, encoding: .utf8) == "second")
        #expect(throws: (any Error).self) { try SharedInbox.save(source, suggestedName: "../escape", in: inbox) }
    }

    @Test
    func `An Inbox symlink is not a writable destination`() throws {
        let scratch = Scratch()
        let group = URL(fileURLWithPath: scratch.directory("group"))
        let outside = scratch.directory("outside")
        #expect(symlink(outside, group.appendingPathComponent("Inbox").path) == 0)
        #expect(throws: (any Error).self) { try SharedInbox.directory(in: group) }
    }
}
