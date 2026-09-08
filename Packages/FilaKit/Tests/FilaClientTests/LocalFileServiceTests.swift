import CRemoveFile
import Darwin
@testable import FilaClient
@testable import FilaProtocol
import Foundation
import Testing

/// The in-process backend, driven through `DaemonLink` exactly as the app
/// drives it.
///
/// Everything below runs against a real directory on a real filesystem, for the
/// same reason `FilaFileOpsTests` does: an operation that is only correct
/// against a mock is not correct. What is under test here is the wiring —
/// that every call reaches `FilaFileOps`, that a job reports on the stream, and
/// that the guard is still in the way — not the file layer itself, which has
/// its own suite.
@Suite("In-process backend")
struct LocalFileServiceTests {
    let scratch = LocalScratch()

    /// A link that has settled on the local backend, the way the app's own
    /// retry loop settles it: ask until it stops throwing. `FileSession`
    /// sleeps between attempts and this does not, because there is nothing to
    /// wait for — the misses only have to be counted.
    private func link() async throws -> DaemonLink {
        let link = DaemonLink(daemonIsInstalled: false)
        while await (try? link.hello()) == nil {}
        return link
    }

    @Test("Lists a directory")
    func lists() async throws {
        scratch.file("one")
        scratch.file("two")
        let page = try await link().list(directory: scratch.root)
        #expect(Set(page.entries.map(\.name)) == ["one", "two"])
        #expect(page.isFinal)
    }

    @Test("The client releases an abandoned listing through its selected backend")
    func cancelsListing() async throws {
        for index in 0 ... FilaProtocol.directoryPageEntryCount { scratch.file("entry-\(index)") }
        let link = try await link()
        let page = try await link.list(directory: scratch.root)
        #expect(!page.isFinal)
        try await link.closeDirectory(cursor: page.cursor)
        let failure = await #expect(throws: FilaFailure.self) {
            _ = try await link.list(directory: scratch.root, cursor: page.cursor)
        }
        #expect(failure?.systemError == ESTALE)
        let replacement = try await link.list(directory: scratch.root)
        #expect(replacement.entries.count == FilaProtocol.directoryPageEntryCount)
        try await link.closeDirectory(cursor: replacement.cursor)
    }

    @Test("Creates, stats and opens a file")
    func createsAndReads() async throws {
        let link = try await link()
        try await link.create(.emptyFile, at: scratch.path("new.txt"))

        let details = try await link.details(of: scratch.path("new.txt"))
        #expect(details.path == scratch.path("new.txt"))
        #expect(!details.isDestructionProtected)

        let descriptor = try await link.open(scratch.path("new.txt"), flags: O_WRONLY)
        #expect(descriptor >= 0)
        #expect(write(descriptor, "fila", 4) == 4)
        close(descriptor)

        let refreshed = try await link.details(of: scratch.path("new.txt"))
        #expect(refreshed.node.size == 4)
    }

    @Test("Renames, and reports the volume it renamed on")
    func renamesAndReportsVolume() async throws {
        let link = try await link()
        scratch.file("before")
        try await link.rename(scratch.path("before"), to: scratch.path("after"), exclusive: true)
        #expect(!exists(scratch.path("before")))
        #expect(exists(scratch.path("after")))

        let volume = try await link.volumeInfo(for: scratch.root)
        #expect(!volume.mountPoint.isEmpty)
    }

    @Test("A copy job runs and reports its completion on the stream")
    func runsAJob() async throws {
        let link = try await link()
        scratch.directory("tree/inner")
        scratch.file("tree/inner/leaf", contents: "bytes")
        let destination = scratch.directory("landing")

        let identifier = try await link.startJob(
            JobRequest(kind: .copy, sources: [scratch.path("tree")], destination: destination)
        )
        var outcome: FilaFailure?
        for await update in link.jobEvents where update.identifier == identifier {
            if case let .completed(failure) = update.event {
                outcome = failure
                break
            }
        }
        #expect(outcome?.code == .success)
        #expect(exists(scratch.path("landing/tree/inner/leaf")))
    }

    /// The one that matters. There is no privilege boundary in this process,
    /// and the guard is enforced all the same — it is the same
    /// `FileOperations` the daemon runs, and refusing to move `/usr` away is
    /// not about privilege, it is about the device still booting.
    @Test("`FilaGuard` refuses a protected node here exactly as in the daemon")
    func guardStillRefuses() async throws {
        let link = try await link()
        await #expect(throws: FilaFailure(code: .protectedPath, path: "/usr")) {
            try await link.rename("/usr", to: scratch.path("usr"))
        }
    }

    @Test("A protected node is reported as protected so the app can grey it out")
    func reportsProtection() async throws {
        let details = try await link().details(of: "/usr")
        #expect(details.isDestructionProtected)
    }
}

/// A real directory, gone when the test is. The `FilaFileOps` suite has its own
/// copy of this; duplicating twenty lines is cheaper than a shared test module
/// between two independent test targets.
final class LocalScratch {
    let root: String

    init() {
        let created = "/private/tmp/fila-client-tests-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
        precondition(mkdir(created, 0o755) == 0, "scratch: \(String(cString: strerror(errno)))")
        root = created
    }

    deinit { removefile(root, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) }

    func path(_ relative: String) -> String {
        root + "/" + relative
    }

    @discardableResult
    func directory(_ relative: String) -> String {
        var built = root
        for component in relative.split(separator: "/") {
            built += "/" + component
            precondition(mkdir(built, 0o755) == 0 || errno == EEXIST, "mkdir \(built)")
        }
        return built
    }

    @discardableResult
    func file(_ relative: String, contents: String = "fila") -> String {
        let path = path(relative)
        let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        precondition(descriptor >= 0, "open \(path)")
        contents.withCString { _ = write(descriptor, $0, strlen($0)) }
        close(descriptor)
        return path
    }
}

func exists(_ path: String) -> Bool {
    var found = stat()
    return lstat(path, &found) == 0
}
