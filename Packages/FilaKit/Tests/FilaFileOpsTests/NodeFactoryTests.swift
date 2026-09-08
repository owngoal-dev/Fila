import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Creating nodes")
struct NodeFactoryTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test("New files and directories use the default owner and exact 0777 mode", arguments: [NodeTemplate.emptyFile, .directory, .symbolicLink(target: "missing")])
    func defaultPermissions(_ template: NodeTemplate) throws {
        let path = scratch.path("new")
        try operations.create(template, at: path)
        let node = try #require(metadata(of: path))
        #expect(node.st_mode & 0o7777 == 0o777)
        #expect(node.st_uid == (geteuid() == 0 ? 501 : getuid()))
        #expect(node.st_gid == (geteuid() == 0 ? 501 : getgid()))
    }

    @Test("Explicit private creation and hard links retain their permissions")
    func preservesSuppliedPermissions() throws {
        let path = scratch.path("private")
        try operations.create(.directory, at: path, mode: 0o700)
        #expect(metadata(of: path).map { $0.st_mode & 0o7777 } == 0o700)
        let original = scratch.file("source", contents: "source", mode: 0o640)
        try operations.create(.hardLink(existing: original), at: scratch.path("link"))
        #expect(metadata(of: original).map { $0.st_mode & 0o7777 } == 0o640)
    }

    @Test("Each template makes what it says")
    func makesEachKind() throws {
        try operations.create(.directory, at: scratch.path("folder"))
        #expect(metadata(of: scratch.path("folder")).map { $0.st_mode & S_IFMT == S_IFDIR } == true)

        try operations.create(.emptyFile, at: scratch.path("empty.txt"))
        #expect(metadata(of: scratch.path("empty.txt"))?.st_size == 0)

        try operations.create(.symbolicLink(target: "empty.txt"), at: scratch.path("pointer"))
        #expect(metadata(of: scratch.path("pointer")).map { $0.st_mode & S_IFMT == S_IFLNK } == true)

        try operations.create(.hardLink(existing: scratch.path("empty.txt")), at: scratch.path("second-name"))
        #expect(metadata(of: scratch.path("second-name"))?.st_ino == metadata(of: scratch.path("empty.txt"))?.st_ino)
    }

    @Test("Creating a file never truncates one that is already there")
    func neverClobbers() {
        scratch.file("existing.txt", contents: "precious")
        let failure = #expect(throws: FilaFailure.self) {
            try operations.create(.emptyFile, at: scratch.path("existing.txt"))
        }
        #expect(failure?.systemError == EEXIST)
        #expect(metadata(of: scratch.path("existing.txt"))?.st_size == 8)
    }

    @Test("Renaming onto an existing name replaces it, and says so to the guard")
    func renameReplaces() throws {
        let source = scratch.file("new.txt", contents: "fresh")
        scratch.file("old.txt", contents: "stale")

        try operations.rename(source, to: scratch.path("old.txt"))
        #expect(!exists(source))
        #expect(metadata(of: scratch.path("old.txt"))?.st_size == 5)
    }

    @Test("An exclusive rename refuses to replace, and leaves both files alone")
    func exclusiveRenameRefusesToReplace() {
        let source = scratch.file("new.txt", contents: "fresh")
        scratch.file("old.txt", contents: "stale")

        // The check-then-act a caller picking a free name would otherwise do:
        // the name it checked can be taken before the rename runs, and POSIX
        // `rename(2)` would destroy what appeared there without a word.
        let failure = #expect(throws: FilaFailure.self) {
            try operations.rename(source, to: scratch.path("old.txt"), exclusive: true)
        }
        #expect(failure?.systemError == EEXIST)
        #expect(metadata(of: source)?.st_size == 5)
        #expect(metadata(of: scratch.path("old.txt"))?.st_size == 5)
    }

    @Test("An exclusive rename into a free name is an ordinary move")
    func exclusiveRenameIntoAFreeName() throws {
        let source = scratch.file("new.txt", contents: "fresh")

        try operations.rename(source, to: scratch.path("moved.txt"), exclusive: true)
        #expect(!exists(source))
        #expect(metadata(of: scratch.path("moved.txt"))?.st_size == 5)
    }
}
