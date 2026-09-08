import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Relocated daemon write boundary")
struct WritableRootTests {
    let scratch = Scratch()
    var root: String {
        scratch.path("bootstrap")
    }

    var operations: FileOperations {
        FileOperations(bootstrapRoot: root, writableRoot: root)
    }

    init() {
        scratch.directory("bootstrap")
        scratch.directory("outside")
    }

    private func run(_ request: JobRequest) -> FilaFailure {
        FileJob(request: request, operations: operations).run { _ in }
    }

    @Test("Outside files remain readable but all mutating open flags are refused")
    func readOnlyOutside() throws {
        let file = scratch.file("outside/keep", contents: "unchanged")
        let descriptor = try operations.open(file, flags: O_RDONLY, mode: 0)
        close(descriptor)
        for flags in [O_WRONLY, O_RDWR, O_RDONLY | O_TRUNC, O_RDONLY | O_CREAT, O_WRONLY | O_APPEND] {
            let failure = #expect(throws: FilaFailure.self) {
                let descriptor = try operations.open(file, flags: flags, mode: 0o600)
                close(descriptor)
            }
            #expect(failure?.systemError == EROFS)
        }
        #expect(metadata(of: file)?.st_size == 9)
        #expect(try operations.details(of: file).isDestructionProtected)
        #expect(throws: FilaFailure.self) {
            let descriptor = try operations.open(scratch.path("outside/new"), flags: O_CREAT | O_RDONLY, mode: 0o600)
            close(descriptor)
        }
        #expect(!exists(scratch.path("outside/new")))
    }

    @Test("Canonical parents, root aliases and component boundaries determine the write scope")
    func canonicalBoundary() throws {
        let alias = scratch.link("alias", to: root)
        let aliased = FileOperations(bootstrapRoot: alias, writableRoot: alias)
        try aliased.create(.emptyFile, at: alias + "/allowed")
        #expect(exists(root + "/allowed"))

        scratch.directory("bootstrap-extra")
        scratch.link("bootstrap/escape", to: scratch.path("outside"))
        for path in [scratch.path("bootstrap-extra/new"), root + "/escape/new", root + "/../outside/new"] {
            let failure = #expect(throws: FilaFailure.self) { try operations.create(.emptyFile, at: path) }
            #expect(failure?.systemError == EROFS)
        }
        #expect(!exists(scratch.path("outside/new")))
        #expect(!exists(scratch.path("bootstrap-extra/new")))
    }

    @Test("Final links can be renamed or removed but never opened for writing")
    func finalSymlink() throws {
        let outside = scratch.file("outside/keep", contents: "unchanged")
        let link = scratch.link("bootstrap/link", to: outside)
        #expect(throws: FilaFailure.self) {
            let descriptor = try operations.open(link, flags: O_WRONLY | O_TRUNC, mode: 0)
            close(descriptor)
        }
        try operations.rename(link, to: root + "/renamed")
        #expect(run(JobRequest(kind: .delete, sources: [root + "/renamed"])).code == .success)
        #expect(metadata(of: outside)?.st_size == 9)

        let dangling = scratch.link("bootstrap/dangling", to: scratch.path("outside/missing"))
        #expect(throws: FilaFailure.self) {
            let descriptor = try operations.open(dangling, flags: O_WRONLY | O_CREAT, mode: 0o600)
            close(descriptor)
        }
        #expect(!exists(scratch.path("outside/missing")))
    }

    @Test("Creation, metadata, rename and replacement cannot write outside")
    func everyMutationUsesBoundary() throws {
        let outside = scratch.file("outside/keep", contents: "unchanged")
        let inside = scratch.file("bootstrap/source", contents: "inside")
        for template in [NodeTemplate.directory, .emptyFile, .symbolicLink(target: inside), .hardLink(existing: inside)] {
            #expect(throws: FilaFailure.self) {
                try operations.create(template, at: scratch.path("outside/new"))
            }
        }
        #expect(throws: FilaFailure.self) { try operations.setAttributes(AttributeChange(mode: 0o600), at: outside) }
        #expect(permissions(of: outside) == 0o644)
        #expect(throws: FilaFailure.self) {
            try operations.rename(inside, to: scratch.path("outside/new"), overrideGuard: true)
        }
        #expect(throws: FilaFailure.self) {
            try operations.rename(outside, to: root + "/new", overrideGuard: true)
        }
        let temporary = scratch.file("outside/temp", contents: "replacement")
        #expect(throws: FilaFailure.self) { try operations.replaceItem(at: outside, withTemporary: temporary) }
        #expect(exists(inside))
        #expect(exists(temporary))
        #expect(metadata(of: outside)?.st_size == 9)
        #expect(!exists(scratch.path("outside/new")))
    }

    @Test("Jobs permit read-only imports and preflight every destructive source")
    func jobBoundary() {
        let outside = scratch.file("outside/import", contents: "outside")
        let inside = scratch.file("bootstrap/keep", contents: "inside")
        #expect(run(JobRequest(kind: .copy, sources: [outside], destination: root)).code == .success)
        #expect(metadata(of: root + "/import")?.st_size == 7)
        #expect(run(JobRequest(kind: .copy, sources: [inside], destination: scratch.path("outside"))).systemError == EROFS)
        #expect(run(JobRequest(kind: .move, sources: [outside], destination: root, overrideGuard: true)).systemError == EROFS)
        #expect(run(JobRequest(kind: .delete, sources: [inside, outside], overrideGuard: true)).systemError == EROFS)
        #expect(exists(inside))
        #expect(exists(outside))
        #expect(!exists(scratch.path("outside/keep")))
    }

    @Test("Bootstrap contents are editable but its node survives every override")
    func rootSurvives() {
        scratch.directory("bootstrap/usr/lib")
        #expect(run(JobRequest(kind: .delete, sources: [root + "/usr"])).code == .success)
        #expect(run(JobRequest(kind: .delete, sources: [root], overrideGuard: true)).code == .protectedPath)
        #expect(operations.isDestructionProtected(root))
        #expect(exists(root))
    }

    @Test("Outside hard links cannot be imported or changed through existing inside names")
    func sharedInodeIsReadOnly() throws {
        let outside = scratch.file("outside/shared", contents: "unchanged")
        #expect(throws: FilaFailure.self) { try operations.create(.hardLink(existing: outside), at: root + "/new-link") }
        let shared = root + "/shared"
        try filaCheck(shared) { Darwin.link(outside, shared) }
        #expect(throws: FilaFailure.self) {
            let descriptor = try operations.open(shared, flags: O_WRONLY | O_TRUNC, mode: 0)
            close(descriptor)
        }
        #expect(throws: FilaFailure.self) { try operations.setAttributes(AttributeChange(mode: 0o600), at: shared) }
        #expect(throws: FilaFailure.self) { try operations.setAttributes(AttributeChange(mode: 0o700, isRecursive: true), at: root) }
        #expect(permissions(of: outside) == 0o644)
        #expect(metadata(of: outside)?.st_size == 9)
        #expect(run(JobRequest(kind: .delete, sources: [shared])).code == .success)
        #expect(exists(outside))
    }

    @Test("Hard-linked symlink metadata cannot change through an inside name")
    func sharedSymlinkMetadataIsReadOnly() throws {
        let outside = scratch.link("outside/shared-link", to: "target")
        let inside = root + "/shared-link"
        try filaCheck(inside) { linkat(AT_FDCWD, outside, AT_FDCWD, inside, 0) }
        let before = try #require(metadata(of: outside))
        #expect(before.st_mode & S_IFMT == S_IFLNK)
        #expect(before.st_nlink == 2)
        #expect(metadata(of: inside)?.st_ino == before.st_ino)

        let failure = #expect(throws: FilaFailure.self) {
            try operations.setAttributes(AttributeChange(mode: 0o600), at: inside)
        }
        #expect(failure?.systemError == EROFS)
        #expect(metadata(of: outside)?.st_mode == before.st_mode)
        #expect(metadata(of: outside)?.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec)
        #expect(metadata(of: outside)?.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
    }

    @Test("Atomic save and copy replace only the inside name of a shared inode")
    func atomicPublicationKeepsOutsideInode() throws {
        let outside = scratch.file("outside/shared", contents: "original")
        let target = root + "/shared"
        try filaCheck(target) { Darwin.link(outside, target) }
        let temporary = scratch.file("bootstrap/temp", contents: "replacement")
        try operations.replaceItem(at: target, withTemporary: temporary)
        #expect(metadata(of: outside)?.st_size == 8)
        #expect(metadata(of: target)?.st_size == 11)
        #expect(metadata(of: outside)?.st_ino != metadata(of: target)?.st_ino)

        let copyTarget = root + "/copy"
        try filaCheck(copyTarget) { Darwin.link(outside, copyTarget) }
        let source = scratch.file("outside/copy", contents: "copied replacement")
        #expect(run(JobRequest(kind: .copy, sources: [source], destination: root, overwrite: true)).code == .success)
        #expect(metadata(of: outside)?.st_size == 8)
        #expect(metadata(of: copyTarget)?.st_size == 18)

        let sharedTemporary = root + "/shared-temp"
        try filaCheck(sharedTemporary) { Darwin.link(outside, sharedTemporary) }
        #expect(throws: FilaFailure.self) { try operations.replaceItem(at: target, withTemporary: sharedTemporary) }
        #expect(metadata(of: outside)?.st_size == 8)
        #expect(exists(sharedTemporary))
    }

    @Test("Trash stays within the writable root, notes the origin, and rejects an outside directory link")
    func trashBoundary() {
        let source = scratch.file("bootstrap/first")
        #expect(run(JobRequest(kind: .delete, sources: [source], useTrash: true)).code == .success)
        #expect(!exists(source))
        let trashed = FilaTrash.directory(under: root) + "/first"
        #expect(exists(trashed))
        #expect(extendedAttribute(FilaTrash.originAttribute, at: trashed) == source)

        let secondRoot = scratch.directory("second-bootstrap")
        scratch.link("second-bootstrap/" + FilaTrash.directoryName, to: scratch.path("outside"))
        let second = scratch.file("second-bootstrap/keep")
        let restricted = FileOperations(bootstrapRoot: secondRoot, writableRoot: secondRoot)
        let result = FileJob(request: JobRequest(kind: .delete, sources: [second], useTrash: true), operations: restricted).run { _ in }
        #expect(result.code != .success)
        #expect(exists(second))
        #expect(!exists(scratch.path("outside/keep")))
    }

    @Test("Unconfigured local and rootful backends retain their previous write access")
    func unconfiguredBackendIsUnchanged() throws {
        let local = FileOperations(bootstrapRoot: "")
        let file = scratch.path("outside/local")
        try local.create(.emptyFile, at: file)
        try local.setAttributes(AttributeChange(mode: 0o600), at: file)
        #expect(permissions(of: file) == 0o600)

        let missingRoot = FileOperations(bootstrapRoot: root, writableRoot: scratch.path("missing"))
        #expect(throws: FilaFailure.self) { try missingRoot.create(.emptyFile, at: root + "/refused") }
        #expect(!exists(root + "/refused"))
    }

    @Test("Path checks reject strings that C syscalls would truncate")
    func rejectsEmbeddedNUL() {
        let malformed = root + "/\0"
        let failure = #expect(throws: FilaFailure.self) { _ = try operations.resolveForDestruction(malformed, overrideGuard: true) }
        #expect(failure?.code == .invalidRequest)
        #expect(throws: FilaFailure.self) { _ = try FilaPath.resolve(malformed) }
        #expect(exists(root))
    }
}
