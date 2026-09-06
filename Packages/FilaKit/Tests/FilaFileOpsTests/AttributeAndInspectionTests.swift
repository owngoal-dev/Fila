import Darwin
import Foundation
import Testing

@testable import FilaFileOps
@testable import FilaProtocol

@Suite("Attributes")
struct AttributeWriterTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test("A recursive change reaches a nested file")
    func recursiveReachesTheBottom() throws {
        scratch.directory("tree/one/two")
        let deep = scratch.file("tree/one/two/leaf.txt", mode: 0o644)
        let shallow = scratch.file("tree/sibling.txt", mode: 0o644)

        // 0o700 rather than 0o600: taking the execute bit off a directory stops
        // the walk that is under test, for the ordinary reason that nobody but
        // root may then read through it.
        try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: scratch.path("tree"))

        #expect(permissions(of: deep) == 0o700)
        #expect(permissions(of: shallow) == 0o700)
        #expect(permissions(of: scratch.path("tree/one")) == 0o700)
    }

    @Test("A recursive change does not walk through a symlink")
    func recursiveStopsAtLinks() throws {
        scratch.directory("tree")
        scratch.directory("outside")
        let outsider = scratch.file("outside/untouched.txt", mode: 0o644)
        scratch.link("tree/escape", to: scratch.path("outside"))

        try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: scratch.path("tree"))
        #expect(permissions(of: scratch.path("tree/escape")) == 0o700)
        #expect(permissions(of: outsider) == 0o644)
    }

    @Test("Times, flags and one extended attribute, each on its own")
    func writesEachField() throws {
        let file = scratch.file("subject.txt")

        try operations.setAttributes(AttributeChange(modified: 1_234_567), at: file)
        #expect(metadata(of: file)?.st_mtimespec.tv_sec == 1_234_567)

        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_HIDDEN)), at: file)
        #expect(hasFlag(UF_HIDDEN, at: file))

        try operations.setAttributes(
            AttributeChange(extendedAttribute: ("wiki.qaq.fila.test", Data("here".utf8))),
            at: file
        )
        #expect(extendedAttribute("wiki.qaq.fila.test", at: file) == "here")

        try operations.setAttributes(
            AttributeChange(extendedAttribute: ("wiki.qaq.fila.test", nil)),
            at: file
        )
        #expect(extendedAttribute("wiki.qaq.fila.test", at: file) == nil)
    }

    @Test("Setting one timestamp leaves the other where it was")
    func keepsTheTimestampItWasNotGiven() throws {
        let file = scratch.file("subject.txt")
        var times = [timeval(tv_sec: 111_111, tv_usec: 0), timeval(tv_sec: 222_222, tv_usec: 0)]
        #expect(lutimes(file, &times) == 0)

        try operations.setAttributes(AttributeChange(modified: 999_999), at: file)
        let after = try #require(metadata(of: file))
        #expect(after.st_mtimespec.tv_sec == 999_999)
        #expect(after.st_atimespec.tv_sec == 111_111)
    }

    @Test("A change on a symlink changes the link, not its target")
    func doesNotFollowTheLeaf() throws {
        let target = scratch.file("target.txt", mode: 0o644)
        let link = scratch.link("pointer", to: target)

        try operations.setAttributes(AttributeChange(systemFlags: UInt32(UF_HIDDEN)), at: link)
        #expect(hasFlag(UF_HIDDEN, at: link))
        #expect(!hasFlag(UF_HIDDEN, at: target))
    }
}

@Suite("Inspection")
struct FileInspectorTests {
    let scratch = Scratch()

    @Test("Details come back under the path every decision was made about")
    func canonicalisesTheReply() throws {
        let operations = FileOperations(bootstrapRoot: "")
        scratch.directory("folder")
        scratch.file("folder/subject.txt", contents: "12345")

        let details = try operations.details(of: scratch.path("folder/../folder/subject.txt"))
        #expect(details.path == scratch.path("folder/subject.txt"))
        #expect(details.node.name == "subject.txt")
        #expect(details.node.size == 5)
        #expect(details.isDestructionProtected == false)
    }

    @Test("Details of a symlink describe the link")
    func describesTheLink() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let target = scratch.file("target.txt")
        let link = scratch.link("pointer", to: target)

        let details = try operations.details(of: link)
        #expect(details.node.kind == .symbolicLink)
        #expect(details.node.link?.target == target)
        #expect(details.node.link?.resolvedKind == .regular)
    }

    @Test("The guard's verdict ships with the details")
    func shipsTheVerdict() throws {
        let operations = FileOperations(bootstrapRoot: scratch.root)
        scratch.directory("usr/lib")
        #expect(try operations.details(of: scratch.path("usr")).isDestructionProtected)
        #expect(try !operations.details(of: scratch.path("usr/lib")).isDestructionProtected)
    }

    @Test("Extended attributes are listed by name and size, never by value")
    func listsAttributes() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let file = scratch.file("subject.txt")
        setExtendedAttribute("wiki.qaq.fila.one", to: "abc", at: file)
        setExtendedAttribute("wiki.qaq.fila.two", to: "abcdef", at: file)

        let details = try operations.details(of: file)
        let sizes = Dictionary(
            uniqueKeysWithValues: details.extendedAttributes.map { ($0.name, $0.byteCount) }
        )
        #expect(sizes["wiki.qaq.fila.one"] == 3)
        #expect(sizes["wiki.qaq.fila.two"] == 6)

        #expect(try operations.extendedAttribute("wiki.qaq.fila.two", at: file) == Data("abcdef".utf8))
    }

    @Test("Volume identity is what says whether a move is a rename")
    func volumeIdentity() throws {
        let operations = FileOperations(bootstrapRoot: "")
        scratch.directory("here")
        let volume = try operations.volumeInfo(for: scratch.path("here"))
        #expect(volume.totalByteCount > 0)
        #expect(!volume.mountPoint.isEmpty)
        #expect(try volume.deviceIdentifier == operations.volumeInfo(for: scratch.root).deviceIdentifier)
    }

    @Test("A descriptor comes back opened, and the daemon read none of it")
    func opensAsRoot() throws {
        let operations = FileOperations(bootstrapRoot: "")
        let file = scratch.file("subject.txt", contents: "abcdef")
        let descriptor = try operations.open(file, flags: O_RDONLY, mode: 0)
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: 16)
        let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 16) }
        #expect(read == 6)
    }

    @Test("A relative path is a client bug, not a path")
    func refusesRelativePaths() {
        let failure = #expect(throws: FilaFailure.self) {
            _ = try FilaPath.canonical("etc/passwd")
        }
        #expect(failure?.code == .invalidRequest)
    }
}

