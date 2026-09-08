import Darwin
import Foundation
import Testing

@testable import FilaFileOps
@testable import FilaProtocol

// Set this to a mounted, writable second volume to exercise real EXDEV paths.
private let trashTestRoots = ["/private/tmp"] + (ProcessInfo.processInfo.environment["FILA_CROSS_VOLUME_TEST_ROOT"].map { [$0] } ?? [])

@Suite("Trash and Put Back")
struct TrashTests {
    @Test("A tree survives trash and restore with metadata and links", arguments: trashTestRoots)
    func roundTrip(bootstrapParent: String) throws {
        let source = Scratch()
        let bootstrap = Scratch(parent: bootstrapParent)
        let operations = FileOperations(bootstrapRoot: bootstrap.root)
        let identity = UUID()
        source.directory("tree/nested")
        let file = source.file("tree/nested/payload", contents: "keep all bytes", mode: 0o640)
        setExtendedAttribute("wiki.qaq.fila.test", to: "metadata", at: file)
        source.link("tree/link", to: "nested/payload")
        source.link("tree/dangling", to: "missing")
        let trash = FilaTrash.directory(under: bootstrap.root) + "/tree"
        let run = { (request: JobRequest) in FileJob(request: request, operations: operations).run { _ in } }
        #expect(run(JobRequest(kind: .delete, sources: [source.path("tree")], useTrash: true, trashID: identity)).code == .success)
        #expect(!exists(source.path("tree")))
        #expect(extendedAttribute(FilaTrash.originAttribute, at: trash) == source.path("tree"))
        #expect(extendedAttribute(FilaTrash.jobAttribute, at: trash) == identity.uuidString)
        #expect(extendedAttribute("wiki.qaq.fila.test", at: trash + "/nested/payload") == "metadata")
        #expect(permissions(of: trash + "/nested/payload") == 0o640)
        #expect((metadata(of: trash + "/dangling")?.st_mode ?? 0) & S_IFMT == S_IFLNK)
        #expect(run(JobRequest(kind: .restore, sources: [trash], trashID: identity)).code == .success)
        #expect(!exists(trash))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep all bytes")
        #expect(extendedAttribute("wiki.qaq.fila.test", at: file) == "metadata")
        #expect(extendedAttribute(FilaTrash.originAttribute, at: source.path("tree")) == nil)
        #expect(extendedAttribute(FilaTrash.jobAttribute, at: source.path("tree")) == nil)
        #expect((metadata(of: source.path("tree/link"))?.st_mode ?? 0) & S_IFMT == S_IFLNK)
    }

    @Test("Colliding trash names restore to their exact origins and refuse replacements", arguments: trashTestRoots)
    func collisions(bootstrapParent: String) throws {
        let source = Scratch()
        let bootstrap = Scratch(parent: bootstrapParent)
        let operations = FileOperations(bootstrapRoot: bootstrap.root)
        let run = { (request: JobRequest) in FileJob(request: request, operations: operations).run { _ in } }
        source.directory("one")
        source.directory("two")
        let first = source.file("one/same", contents: "first")
        let second = source.file("two/same", contents: "second")
        let identity = UUID()
        let trash = FilaTrash.directory(under: bootstrap.root)
        #expect(run(JobRequest(kind: .delete, sources: [first, second], useTrash: true, trashID: identity, overwrite: true)).code == .success)
        #expect(try String(contentsOfFile: trash + "/same", encoding: .utf8) == "first")
        #expect(try String(contentsOfFile: trash + "/same-1", encoding: .utf8) == "second")
        #expect(run(JobRequest(kind: .restore, sources: [trash + "/same-1"], trashID: UUID())).code == .notFound)
        source.file("two/same", contents: "new owner")
        #expect(run(JobRequest(kind: .restore, sources: [trash + "/same-1"], overwrite: true)).systemError == EEXIST)
        #expect(try String(contentsOfFile: second, encoding: .utf8) == "new owner")
        #expect(exists(trash + "/same-1"))
        #expect(unlink(second) == 0)
        #expect(run(JobRequest(kind: .restore, sources: [trash + "/same-1"], trashID: identity)).code == .success)
        #expect(exists(second))
        #expect(!exists(source.path("two/same-1")))
        #expect(exists(trash + "/same"))
    }

    @Test("Restore refuses malformed origins, missing records, and paths outside a provider root")
    func invalidOrigins() throws {
        let scratch = Scratch()
        let root = scratch.directory("root")
        let trash = scratch.directory("root/.fila-trash")
        let file = scratch.file("root/.fila-trash/item")
        let operations = FileOperations(bootstrapRoot: "", writableRoot: root)
        let request = JobRequest(kind: .restore, sources: [file])
        let run = { FileJob(request: request, operations: operations).run { _ in } }
        #expect(run().systemError == ENOATTR)
        try operations.setAttributes(AttributeChange(extendedAttribute: (FilaTrash.originAttribute, Data((root + "/name\0truncated").utf8))), at: file)
        #expect(run().code != .success)
        setExtendedAttribute(FilaTrash.originAttribute, to: scratch.path("outside"), at: file)
        #expect(run().systemError == EROFS)
        setExtendedAttribute(FilaTrash.originAttribute, to: trash + "/other", at: file)
        #expect(run().code == .invalidRequest)
        #expect(exists(file))
        #expect(!exists(scratch.path("outside")))
    }

    @Test("Cancelled trash leaves the source and existing trash alone", arguments: trashTestRoots)
    func cancellation(bootstrapParent: String) throws {
        let source = Scratch()
        let bootstrap = Scratch(parent: bootstrapParent)
        let file = source.file("payload")
        let operations = FileOperations(bootstrapRoot: bootstrap.root)
        let job = FileJob(request: JobRequest(kind: .delete, sources: [file], useTrash: true), operations: operations)
        let result = job.run { _ in job.cancel() }
        #expect(result.code == .cancelled)
        #expect(exists(file))
        #expect(!exists(FilaTrash.directory(under: bootstrap.root) + "/payload"))
    }
    @Test("A failed cross-volume copy keeps the whole source and cleans staging", .enabled(if: trashTestRoots.count > 1 && geteuid() != 0))
    func failedCopy() throws {
        let source = Scratch()
        let bootstrap = Scratch(parent: try #require(trashTestRoots.last))
        #expect(!filaSameVolume(source.root, bootstrap.root))
        source.directory("tree/locked")
        let file = source.file("tree/locked/item", contents: "irreplaceable")
        #expect(chmod(source.path("tree/locked"), 0) == 0)
        defer { chmod(source.path("tree/locked"), 0o755) }
        let operations = FileOperations(bootstrapRoot: bootstrap.root)
        let result = FileJob(request: JobRequest(kind: .delete, sources: [source.path("tree")], useTrash: true), operations: operations).run { _ in }
        #expect(result.code != .success)
        #expect(exists(source.path("tree")))
        #expect(chmod(source.path("tree/locked"), 0o755) == 0)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "irreplaceable")
        #expect(try FileManager.default.contentsOfDirectory(atPath: FilaTrash.directory(under: bootstrap.root)).isEmpty)
    }

    @Test("Failed source removal retains a complete trash copy with its origin", .enabled(if: trashTestRoots.count > 1))
    func failedRemoval() throws {
        let source = Scratch()
        let bootstrap = Scratch(parent: try #require(trashTestRoots.last))
        #expect(!filaSameVolume(source.root, bootstrap.root))
        source.directory("tree")
        let file = source.file("tree/locked", contents: "recoverable")
        #expect(chflags(file, UInt32(UF_IMMUTABLE)) == 0)
        let trash = FilaTrash.directory(under: bootstrap.root) + "/tree"
        defer {
            chflags(file, 0)
            chflags(trash + "/locked", 0)
        }
        let operations = FileOperations(bootstrapRoot: bootstrap.root)
        let identity = UUID()
        let result = FileJob(request: JobRequest(kind: .delete, sources: [source.path("tree")], useTrash: true, trashID: identity), operations: operations).run { _ in }
        #expect(result.code != .success)
        #expect(try String(contentsOfFile: trash + "/locked", encoding: .utf8) == "recoverable")
        #expect(extendedAttribute(FilaTrash.originAttribute, at: trash) == source.path("tree"))
        #expect(extendedAttribute(FilaTrash.jobAttribute, at: trash) == identity.uuidString)
        #expect(exists(file))
    }

}
