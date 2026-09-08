import Darwin
import Foundation
import Testing

@testable import FilaFileOps
@testable import FilaProtocol

/// The mount point of the volume the scratch directory lives on. The trash the
/// daemon uses is `<mount point>/.fila-trash`, and the tests below have to
/// look in the same place the production code chose.
let filaScratchMountPoint: String = {
    var volume = statfs()
    guard statfs("/private/tmp", &volume) == 0 else { return "/" }
    return filaText(volume.f_mntonname)
}()

/// Whether an ordinary user may create the trash at that mount point. True on a
/// normal Mac, where `/private/tmp` lives on the writable Data volume; false for
/// a user who is not in `admin`. Read-only on purpose: deciding whether to run a
/// test must not itself leave a directory behind at a volume root.
let filaTrashIsReachable = access(filaScratchMountPoint, W_OK) == 0

/// The scratch volume's trash.
let filaTrashDirectory = FilaTrash.directory(under: filaScratchMountPoint)

/// Takes back what the test put in the shared trash, and the directory with
/// it when it is empty — this is a real trash on the developer's own machine
/// and a test has no business accumulating in it.
func emptyTestTrash(_ names: [String]) {
    for name in names { unlink(filaTrashDirectory + "/" + name) }
    rmdir(filaTrashDirectory)
}

/// Serialized because two of these tests share one directory that cannot be
/// made unique: the trash is `<mount point>/.fila-trash` and the production
/// code picks it, not the test. Run in parallel, one test's cleanup `rmdir`s
/// the directory the other is mid-delete into, and the failure lands on
/// whichever test lost the race — roughly one run in five.
@Suite("Jobs", .serialized)
struct JobTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    private func run(_ request: JobRequest, report: @escaping (JobProgress) -> Void = { _ in }) -> FilaFailure {
        FileJob(request: request, operations: operations).run(report: report)
    }

    // MARK: - Copy

    @Test("A copy keeps extended attributes and leaves a symlink a symlink")
    func copyPreservesTheThingsAHandWrittenWalkLoses() throws {
        scratch.directory("source/nested")
        let file = scratch.file("source/nested/data.bin", contents: "payload")
        setExtendedAttribute("wiki.qaq.fila.test", to: "kept", at: file)
        scratch.link("source/pointer", to: "nested/data.bin")
        scratch.directory("destination")

        #expect(run(JobRequest(
            kind: .copy,
            sources: [scratch.path("source")],
            destination: scratch.path("destination")
        )).code == .success)

        let copied = scratch.path("destination/source/nested/data.bin")
        #expect(extendedAttribute("wiki.qaq.fila.test", at: copied) == "kept")

        let link = try #require(metadata(of: scratch.path("destination/source/pointer")))
        #expect(FileKind(modeBits: link.st_mode) == .symbolicLink)
    }

    @Test("Overwriting an existing destination preserves copied metadata")
    func copyOverExisting() throws {
        scratch.directory("destination")
        let source = scratch.file("payload.txt", contents: "new contents")
        setExtendedAttribute("wiki.qaq.fila.test", to: "kept", at: source)
        scratch.file("destination/payload.txt", contents: "stale")

        #expect(run(JobRequest(
            kind: .copy,
            sources: [source],
            destination: scratch.path("destination"),
            overwrite: true
        )).code == .success)

        let target = scratch.path("destination/payload.txt")
        #expect(metadata(of: target)?.st_size == 12)
        #expect(extendedAttribute("wiki.qaq.fila.test", at: target) == "kept")
    }

    @Test("A collision without overwrite fails and changes nothing")
    func copyRefusesToClobber() {
        scratch.directory("destination")
        scratch.file("payload.txt", contents: "new")
        scratch.file("destination/payload.txt", contents: "stale")

        let outcome = run(JobRequest(
            kind: .copy,
            sources: [scratch.path("payload.txt")],
            destination: scratch.path("destination")
        ))
        #expect(outcome.systemError == EEXIST)
        #expect(metadata(of: scratch.path("destination/payload.txt"))?.st_size == 5)
    }

    @Test("Copy publishes a replacement inode and leaves existing hard links intact")
    func copyPublishesAtomically() throws {
        scratch.directory("destination")
        let source = scratch.file("payload.txt", contents: "replacement")
        let target = scratch.file("destination/payload.txt", contents: "original")
        let previous = scratch.path("previous.txt")
        try #require(link(target, previous) == 0)

        #expect(run(JobRequest(kind: .copy, sources: [source], destination: scratch.path("destination"), overwrite: true)).code == .success)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "replacement")
        #expect(try String(contentsOfFile: previous, encoding: .utf8) == "original")
        #expect(metadata(of: target)?.st_ino != metadata(of: previous)?.st_ino)
    }

    @Test("Copy and move reject an occupied target that appears after preflight", arguments: [FilaJobKind.copy, .move])
    func transferPublishesExclusively(_ kind: FilaJobKind) throws {
        scratch.directory("destination")
        let source = scratch.file("payload.txt", contents: "source")
        let target = scratch.path("destination/payload.txt")
        let outcome = run(JobRequest(kind: kind, sources: [source], destination: scratch.path("destination"))) { _ in
            if !exists(target) { self.scratch.file("destination/payload.txt", contents: "arrived") }
        }
        #expect(outcome.systemError == EEXIST)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "source")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "arrived")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path("destination")) == ["payload.txt"])
    }

    @Test("Conflicting or overlapping selections fail before changing any item", arguments: [FilaJobKind.copy, .move])
    func transferPreflightsTheWholeSelection(_ kind: FilaJobKind) throws {
        scratch.directory("first")
        scratch.directory("second")
        let first = scratch.file("first/payload.txt", contents: "one")
        let second = scratch.file("second/payload.txt", contents: "two")
        let destination = scratch.directory("destination")
        for sources in [[first, second], [first, first], [scratch.path("first"), first]] {
            #expect(run(JobRequest(kind: kind, sources: sources, destination: destination, overwrite: true)).code == .invalidRequest)
            #expect(try String(contentsOfFile: first, encoding: .utf8) == "one")
            #expect(try String(contentsOfFile: second, encoding: .utf8) == "two")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        }
    }

    @Test("Same-directory paste leaves its source intact", arguments: [FilaJobKind.copy, .move])
    func transferRefusesItself(_ kind: FilaJobKind) throws {
        let source = scratch.file("payload.txt", contents: "keep")
        for overwrite in [false, true] {
            let result = run(JobRequest(kind: kind, sources: [source], destination: scratch.root, overwrite: overwrite))
            #expect(result.code == .invalidRequest)
            #expect(result.reason == .sameLocation)
            #expect(try String(contentsOfFile: source, encoding: .utf8) == "keep")
        }
    }

    @Test("Same-item and descendant refusals survive aliases", arguments: [FilaJobKind.copy, .move])
    func transferExplainsAliases(_ kind: FilaJobKind) throws {
        let source = scratch.file("payload.txt", contents: "keep")
        let alias = scratch.link("alias", to: scratch.root)
        #expect(run(JobRequest(kind: kind, sources: [source], destination: alias)).reason == .sameLocation)
        let destination = scratch.directory("destination")
        let target = scratch.path("destination/payload.txt")
        #expect(Darwin.link(source, target) == 0)
        #expect(run(JobRequest(kind: kind, sources: [source], destination: destination, overwrite: true)).reason == .sameItem)
        let nested = scratch.directory("tree/nested")
        let nestedAlias = scratch.link("nested-alias", to: nested)
        #expect(run(JobRequest(kind: kind, sources: [scratch.path("tree")], destination: nestedAlias)).reason == .insideSource)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "keep")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested).isEmpty)
    }

    @Test("File-folder conflicts reject the whole batch before writes", arguments: [FilaJobKind.copy, .move])
    func transferExplainsIncompatibleTypes(_ kind: FilaJobKind) throws {
        let first = scratch.file("first.txt", contents: "first")
        let source = scratch.file("payload", contents: "keep")
        let destination = scratch.directory("destination")
        scratch.directory("destination/payload")
        for overwrite in [false, true] {
            let result = run(JobRequest(kind: kind, sources: [first, source], destination: destination, overwrite: overwrite))
            #expect(result.reason == .differentItemKinds)
            #expect(!exists(scratch.path("destination/first.txt")))
            #expect(try String(contentsOfFile: first, encoding: .utf8) == "first")
            #expect(try String(contentsOfFile: source, encoding: .utf8) == "keep")
            #expect(metadata(of: scratch.path("destination/payload")).map { $0.st_mode & S_IFMT == S_IFDIR } == true)
        }
    }

    @Test("A directory destination may be reached through a symlink", arguments: [FilaJobKind.copy, .move])
    func transferUsesTheDestinationDirectory(_ kind: FilaJobKind) throws {
        let destination = scratch.directory("destination")
        let alias = scratch.link("alias", to: destination)
        let source = scratch.file("payload.txt", contents: "content")
        #expect(run(JobRequest(kind: kind, sources: [source], destination: alias)).code == .success)
        #expect(try String(contentsOfFile: scratch.path("destination/payload.txt"), encoding: .utf8) == "content")
        #expect(metadata(of: alias).map { FileKind(modeBits: $0.st_mode) } == .symbolicLink)
    }

    @Test("An approved overwrite never merges a nonempty destination directory", arguments: [FilaJobKind.copy, .move])
    func transferPreservesBothNonemptyTrees(_ kind: FilaJobKind) throws {
        let source = scratch.directory("tree")
        scratch.file("tree/new.txt", contents: "new")
        let destination = scratch.directory("destination")
        scratch.directory("destination/tree")
        scratch.file("destination/tree/old.txt", contents: "old")
        #expect(run(JobRequest(kind: kind, sources: [source], destination: destination, overwrite: true)).systemError == ENOTEMPTY)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source) == ["new.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path("destination/tree")) == ["old.txt"])
    }

    @Test("Cancelling an overwrite preserves the old destination")
    func cancelledOverwritePreservesDestination() throws {
        scratch.directory("destination")
        let source = scratch.file("payload.txt", contents: "new")
        let target = scratch.file("destination/payload.txt", contents: "old")
        let job = FileJob(request: JobRequest(kind: .copy, sources: [source], destination: scratch.path("destination"), overwrite: true), operations: operations)
        #expect(job.run { _ in job.cancel() }.code == .cancelled)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path("destination")) == ["payload.txt"])
    }

    @Test("A failed publication cleans the temporary tree including copied immutable items")
    func failedPublicationCleansCopiedFlags() throws {
        let source = scratch.directory("tree")
        let file = scratch.file("tree/kept.txt", contents: "source")
        try #require(lchflags(file, UInt32(UF_IMMUTABLE)) == 0)
        defer { lchflags(file, 0) }
        let destination = scratch.directory("destination")
        let target = scratch.path("destination/tree")
        let outcome = run(JobRequest(kind: .copy, sources: [source], destination: destination)) { _ in
            if !exists(target) { self.scratch.file("destination/tree", contents: "arrived") }
        }
        #expect(outcome.systemError == EEXIST)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["tree"])
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "arrived")
        #expect(hasFlag(UF_IMMUTABLE, at: file))
    }

    @Test("A copy that cannot read part of the tree fails instead of reporting success")
    func partialCopyIsAFailure() throws {
        scratch.directory("source/readable")
        scratch.file("source/readable/data.bin", contents: "payload")
        scratch.directory("source/locked")
        scratch.file("source/locked/secret.bin", contents: "payload")
        // Unreadable to its owner as well, so the test means the same thing
        // whether or not it is run as root... except as root, which reads it
        // anyway; hence the enablement below.
        #expect(chmod(scratch.path("source/locked"), 0o000) == 0)
        defer { chmod(scratch.path("source/locked"), 0o755) }
        scratch.directory("destination")

        let outcome = run(JobRequest(
            kind: .copy,
            sources: [scratch.path("source")],
            destination: scratch.path("destination")
        ))
        #expect(outcome.code != .success)
        #expect(outcome.code != .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path("destination")).isEmpty)
    }

    @Test("A cross-volume move never removes what it could not copy")
    func failedMoveKeepsItsSource() {
        // Same volume here, so this exercises the ordering rather than the
        // cross-volume path: the copy has to come back clean before anything is
        // removed, and a destination inside the source makes the copy fail.
        scratch.directory("tree/inner")
        let payload = scratch.file("tree/payload.txt", contents: "irreplaceable")

        let outcome = run(JobRequest(
            kind: .move,
            sources: [scratch.path("tree")],
            destination: scratch.path("tree/inner")
        ))
        #expect(outcome.code != .success)
        #expect(exists(payload))
    }

    // MARK: - Move

    @Test("A move on one volume is a rename")
    func moveWithinAVolume() {
        scratch.directory("destination")
        scratch.file("payload.txt", contents: "bytes")

        #expect(run(JobRequest(
            kind: .move,
            sources: [scratch.path("payload.txt")],
            destination: scratch.path("destination")
        )).code == .success)

        #expect(!exists(scratch.path("payload.txt")))
        #expect(exists(scratch.path("destination/payload.txt")))
    }

    // MARK: - Delete

    @Test("A permanent delete takes the link, not what it points at")
    func deleteDoesNotFollowLinks() {
        let target = scratch.file("target.txt")
        scratch.link("pointer", to: target)

        #expect(run(JobRequest(kind: .delete, sources: [scratch.path("pointer")])).code == .success)
        #expect(!exists(scratch.path("pointer")))
        #expect(exists(target))
    }

    @Test("A delete to the trash moves the file there, keeps it, and notes where it came from", .enabled(if: filaTrashIsReachable))
    func deleteToTrash() throws {
        defer { emptyTestTrash(["keepsake.txt"]) }
        let doomed = scratch.file("keepsake.txt", contents: "recoverable")

        #expect(run(JobRequest(kind: .delete, sources: [doomed], useTrash: true)).code == .success)
        #expect(!exists(doomed))
        #expect(metadata(of: filaTrashDirectory + "/keepsake.txt")?.st_size == 11)
        #expect(extendedAttribute(FilaTrash.originAttribute, at: filaTrashDirectory + "/keepsake.txt") == (try FilaPath.canonical(doomed)))
    }

    @Test("Two deletes of one name both survive in the trash", .enabled(if: filaTrashIsReachable))
    func trashDoesNotOverwriteItself() {
        defer { emptyTestTrash(["same-name.txt", "same-name.txt-1"]) }
        scratch.directory("first")
        scratch.directory("second")
        let one = scratch.file("first/same-name.txt", contents: "one")
        let two = scratch.file("second/same-name.txt", contents: "twotwo")

        #expect(run(JobRequest(kind: .delete, sources: [one], useTrash: true)).code == .success)
        #expect(run(JobRequest(kind: .delete, sources: [two], useTrash: true)).code == .success)
        #expect(metadata(of: filaTrashDirectory + "/same-name.txt")?.st_size == 3)
        #expect(metadata(of: filaTrashDirectory + "/same-name.txt-1")?.st_size == 6)
    }

    // MARK: - Cancellation

    @Test("Cancellation at the first progress update is reported before publication")
    func cancellationIsReported() {
        scratch.directory("source")
        for index in 0 ..< 200 { scratch.file("source/entry-\(index)", contents: "some bytes here") }
        scratch.directory("destination")
        scratch.directory("destination/source")

        let job = FileJob(
            request: JobRequest(
                kind: .copy,
                sources: [scratch.path("source")],
                destination: scratch.path("destination"),
                overwrite: true
            ),
            operations: operations
        )
        let outcome = job.run { _ in job.cancel() }
        #expect(outcome.code == .cancelled)
    }

    @Test("A job cancelled before it starts never touches anything")
    func cancellationBeforeTheFirstSource() {
        let doomed = scratch.file("payload.txt")
        let job = FileJob(request: JobRequest(kind: .delete, sources: [doomed]), operations: operations)
        job.cancel()
        #expect(job.run { _ in }.code == .cancelled)
        #expect(exists(doomed))
    }

    // MARK: - Progress

    @Test("Progress arrives with unknown totals rather than a counting pre-pass")
    func progressLeavesTotalsUnknown() {
        scratch.directory("source")
        for index in 0 ..< 30 { scratch.file("source/entry-\(index)", contents: "bytes") }
        scratch.directory("destination")
        scratch.directory("destination/source")

        let seen = Reported()
        #expect(run(
            JobRequest(
                kind: .copy,
                sources: [scratch.path("source")],
                destination: scratch.path("destination"),
                overwrite: true
            ),
            report: { seen.append($0) }
        ).code == .success)

        #expect(!seen.values.isEmpty)
        #expect(seen.values.allSatisfy { $0.bytesTotal == 0 && $0.fraction == nil })
        #expect((seen.values.last?.itemsDone ?? 0) > 0)
    }
}

/// Progress arrives on the job's own thread; this just holds what it said.
final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JobProgress] = []

    func append(_ progress: JobProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [JobProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
