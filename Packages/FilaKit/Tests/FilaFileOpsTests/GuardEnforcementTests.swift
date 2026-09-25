import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// The guard is enforced in the daemon and nowhere else, so this is where it is
/// tested: against real files, through the operations that would destroy them.
///
/// The scratch directory stands in for the bootstrap root, which makes it and
/// the handful of directories the jailbreak shadows — `usr`, `Library`,
/// `Applications` — protected on a filesystem the test is allowed to break.
@Suite("The guard, enforced")
struct GuardEnforcementTests {
    let scratch = Scratch()
    var operations: FileOperations {
        FileOperations(bootstrapRoot: scratch.root)
    }

    private func run(_ request: JobRequest) -> FilaFailure {
        FileJob(request: request, operations: operations).run { _ in }
    }

    @Test
    func `A protected node cannot be deleted`() {
        scratch.directory("usr/lib")
        let outcome = run(JobRequest(kind: .delete, sources: [scratch.path("usr")]))
        #expect(outcome.code == .protectedPath)
        #expect(exists(scratch.path("usr")))
    }

    @Test
    func `A protected node cannot be moved away`() {
        scratch.directory("usr")
        scratch.directory("elsewhere")
        #expect(throws: FilaFailure.self) {
            try operations.rename(scratch.path("usr"), to: scratch.path("elsewhere/usr"))
        }
        #expect(exists(scratch.path("usr")))
    }

    @Test
    func `A protected node cannot be replaced`() {
        scratch.directory("usr")
        scratch.file("usr-new")
        let failure = #expect(throws: FilaFailure.self) {
            try operations.replaceItem(at: scratch.path("usr"), withTemporary: scratch.path("usr-new"))
        }
        #expect(failure?.code == .protectedPath)
    }

    @Test
    func `Everything one level inside a protected node stays editable`() throws {
        scratch.directory("usr/lib")
        scratch.file("usr/lib/keep")
        scratch.file("usr/lib/doomed")
        scratch.directory("elsewhere")

        try operations.rename(scratch.path("usr/lib/keep"), to: scratch.path("elsewhere/keep"))
        #expect(exists(scratch.path("elsewhere/keep")))

        let outcome = run(JobRequest(kind: .delete, sources: [scratch.path("usr/lib/doomed")]))
        #expect(outcome.code == .success)
        #expect(!exists(scratch.path("usr/lib/doomed")))
    }

    @Test
    func `The override releases a protected node`() {
        scratch.directory("usr/lib")
        let outcome = run(JobRequest(kind: .delete, sources: [scratch.path("usr")], overrideGuard: true))
        #expect(outcome.code == .success)
        #expect(!exists(scratch.path("usr")))
    }

    @Test
    func `The override does not release the volume root`() {
        let failure = #expect(throws: FilaFailure.self) {
            _ = try operations.resolveForDestruction("/", overrideGuard: true)
        }
        #expect(failure?.code == .protectedPath)
    }

    @Test
    func `The override does not release the bootstrap root`() {
        let failure = #expect(throws: FilaFailure.self) {
            _ = try operations.resolveForDestruction(scratch.root, overrideGuard: true)
        }
        #expect(failure?.code == .protectedPath)
        #expect(exists(scratch.root))
    }

    @Test
    func `The override does not release what contains the bootstrap root either`() {
        // Deleting `/private/var` takes `/var/jb` with it, so an override that
        // stopped only at the exact bootstrap path would leave the hole open.
        let parent = FilaPath.directory(of: scratch.root)
        let failure = #expect(throws: FilaFailure.self) {
            _ = try operations.resolveForDestruction(parent, overrideGuard: true)
        }
        #expect(failure?.code == .protectedPath)
        #expect(exists(parent))
    }

    @Test
    func `A symlink to a protected node is judged by what it points at`() {
        // This is `/var`: the guard's list spells that directory
        // `/private/var`, and the link is what the device boots through.
        // Canonicalising only the parent leaves the link spelled as itself, so
        // the target has to be judged too or `removefile` unlinks it.
        scratch.directory("usr")
        let link = scratch.link("usr-link", to: scratch.path("usr"))

        let outcome = run(JobRequest(kind: .delete, sources: [link]))
        #expect(outcome.code == .protectedPath)
        #expect(exists(link))
    }

    @Test
    func `A symlink to an ordinary node is still deletable, and only the link goes`() {
        let target = scratch.file("ordinary.txt")
        let link = scratch.link("ordinary-link", to: target)

        #expect(run(JobRequest(kind: .delete, sources: [link])).code == .success)
        #expect(!exists(link))
        #expect(exists(target))
    }

    @Test
    func `A temporary that is a protected node cannot be renamed away by a replace`() {
        scratch.directory("usr")
        let failure = #expect(throws: FilaFailure.self) {
            try operations.replaceItem(at: scratch.path("usr-x"), withTemporary: scratch.path("usr"))
        }
        #expect(failure?.code == .protectedPath)
        #expect(exists(scratch.path("usr")))
        #expect(!exists(scratch.path("usr-x")))
    }

    @Test
    func `A job refuses before it destroys the items it would have reached first`() {
        // The second source lands on the protected `usr`; the first lands on an
        // ordinary file. Resolving inside the loop would overwrite the ordinary
        // one and only then refuse.
        scratch.directory("usr")
        scratch.file("first", contents: "stale")
        scratch.directory("source")
        scratch.file("source/first", contents: "fresh bytes")
        scratch.directory("source/usr")

        let outcome = run(JobRequest(
            kind: .copy,
            sources: [scratch.path("source/first"), scratch.path("source/usr")],
            destination: scratch.root,
            overwrite: true,
        ))
        #expect(outcome.code == .protectedPath)
        #expect(metadata(of: scratch.path("first"))?.st_size == 5)
    }

    @Test
    func `A destination inside its own source is refused, not recursed into`() {
        scratch.directory("tree/inner")
        scratch.file("tree/payload.txt")

        let outcome = run(JobRequest(
            kind: .copy,
            sources: [scratch.path("tree")],
            destination: scratch.path("tree/inner"),
        ))
        #expect(outcome.systemError == EINVAL)
        #expect(!exists(scratch.path("tree/inner/tree")))
    }

    @Test
    func `A path that walks in through .. is judged after the kernel resolves it`() {
        scratch.directory("usr/lib")
        let sideways = scratch.path("usr/lib/../../usr")
        #expect(throws: FilaFailure.self) {
            _ = try operations.resolveForDestruction(sideways)
        }
    }

    @Test
    func `Overwriting a protected node is destroying it`() {
        scratch.directory("usr")
        scratch.directory("source")
        scratch.file("source/usr")
        let outcome = run(JobRequest(
            kind: .copy,
            sources: [scratch.path("source/usr")],
            destination: scratch.root,
            overwrite: true,
        ))
        #expect(outcome.code == .protectedPath)
    }

    @Test
    func `Copying out of a protected node is not destruction and is allowed`() {
        scratch.directory("usr")
        scratch.file("usr/payload", contents: "bytes")
        scratch.directory("out")
        let outcome = run(JobRequest(kind: .copy, sources: [scratch.path("usr")], destination: scratch.path("out")))
        #expect(outcome.code == .success)
        #expect(exists(scratch.path("out/usr/payload")))
    }
}
