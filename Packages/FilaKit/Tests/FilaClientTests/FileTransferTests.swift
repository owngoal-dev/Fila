import Darwin
import FilaBackendKit
@testable import FilaClient
@testable import FilaProtocol
import Foundation
import Testing

/// `FileTransfer` between two local roots standing in for two backends —
/// every byte lands on a real filesystem, and both ends are checked after
/// each run, not just the error that came back.
///
/// The wrappers below stand between the executor and the adapter to
/// inject what a real remote can do: change a file after it was read,
/// refuse a removal, lose a publication reply, or offer no descriptor so
/// the file is staged.
@Suite("Cross-backend transfer")
@MainActor
struct FileTransferTests {
    let source = LocalScratch()
    let destination = LocalScratch()
    let stagingScratch = LocalScratch()

    private var staging: URL { URL(fileURLWithPath: stagingScratch.root, isDirectory: true) }

    private func adapter(_ scratch: LocalScratch) -> LocalFileServiceAdapter {
        LocalFileServiceAdapter(access: LocalFileService(), rootPath: scratch.root, observation: DirectoryObservation())
    }

    private func request(
        _ paths: [String],
        mode: TransferMode,
        policy: PublishPolicy = .failIfExists,
        source sourceService: (any FileService)? = nil,
        destination destinationService: (any WritableFileService)? = nil,
        into directory: String = ""
    ) throws -> TransferRequest {
        TransferRequest(
            source: TransferSource(
                backend: BackendID("a"),
                service: sourceService ?? adapter(source),
                paths: try paths.map(ServicePath.init)
            ),
            destination: TransferDestination(
                backend: BackendID("b"),
                service: destinationService ?? adapter(destination),
                directory: try ServicePath(directory)
            ),
            mode: mode,
            policy: policy
        )
    }

    private func run(_ request: TransferRequest, progress: ReportLog = ReportLog()) async -> TransferOutcome {
        await FileTransfer.run(request, staging: staging) { progress.append($0) }
    }

    private func contents(_ scratch: LocalScratch, _ relative: String) -> Data? {
        FileManager.default.contents(atPath: scratch.path(relative))
    }

    private func names(_ scratch: LocalScratch, _ relative: String = "") -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? scratch.root : scratch.path(relative))) ?? [])
    }

    private func isDirectory(_ scratch: LocalScratch, _ relative: String) -> Bool {
        var status = stat()
        return lstat(scratch.path(relative), &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// A tree with a nested file, an empty directory and a large file.
    private func plantTree() -> Data {
        let big = Data((0 ..< (2 * LocalFileServiceAdapter.chunkSize + 11)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        source.directory("tree/sub")
        source.directory("tree/empty")
        source.file("tree/a.txt", contents: "alpha")
        FileManager.default.createFile(atPath: source.path("tree/sub/big.bin"), contents: big)
        return big
    }

    private func expectTree(in scratch: LocalScratch, under prefix: String, big: Data) {
        #expect(contents(scratch, "\(prefix)/a.txt") == Data("alpha".utf8))
        #expect(contents(scratch, "\(prefix)/sub/big.bin") == big)
        #expect(isDirectory(scratch, "\(prefix)/empty"))
        #expect(names(scratch, "\(prefix)/empty").isEmpty)
    }

    // MARK: - Copies

    @Test("A file is copied, verified, and both ends say so")
    func copiesFile() async throws {
        source.file("one.txt", contents: "hello")
        let progress = ReportLog()
        let outcome = await run(try request(["one.txt"], mode: .copy), progress: progress)
        #expect(outcome.succeeded, "\(String(describing: outcome.failure))")
        #expect(outcome.publishedFiles == 1)
        #expect(contents(destination, "one.txt") == Data("hello".utf8))
        #expect(contents(source, "one.txt") == Data("hello".utf8))
        #expect(!names(destination).contains { $0.hasPrefix(".fila-transfer-") })
        #expect(Set(outcome.affected) == [
            FileLocation(backend: BackendID("b"), path: .root),
            FileLocation(backend: BackendID("a"), path: .root),
        ])
        let last = try #require(progress.reports.last)
        #expect(last.bytesTotal == 5, "one leg: the source hands out a descriptor")
        #expect(last.bytesDone == 5)
        #expect(last.itemsDone == 1 && last.itemsTotal == 1)
        #expect(!last.planning)
    }

    @Test("A tree is copied with its hierarchy and its empty directories")
    func copiesTree() async throws {
        let big = plantTree()
        let outcome = await run(try request(["tree"], mode: .copy))
        #expect(outcome.succeeded, "\(String(describing: outcome.failure))")
        expectTree(in: destination, under: "tree", big: big)
        expectTree(in: source, under: "tree", big: big)
        #expect(outcome.publishedFiles == 2)
    }

    @Test("A staged source counts both legs and leaves the staging directory empty")
    func stagedSource() async throws {
        let big = plantTree()
        let progress = ReportLog()
        let staged = StagedService(inner: adapter(source))
        let outcome = await run(try request(["tree"], mode: .copy, source: staged), progress: progress)
        #expect(outcome.succeeded, "\(String(describing: outcome.failure))")
        expectTree(in: destination, under: "tree", big: big)
        let last = try #require(progress.reports.last)
        #expect(last.bytesTotal == 2 * Int64(big.count + 5), "download and upload")
        #expect(last.bytesDone == last.bytesTotal)
        #expect(names(stagingScratch).isEmpty, "every staged file was removed")
    }

    @Test("An occupied name is refused unless replacing, and replacing merges a directory")
    func occupiedDestination() async throws {
        source.file("one.txt", contents: "new")
        destination.file("one.txt", contents: "old")
        let refused = await run(try request(["one.txt"], mode: .copy))
        #expect(refused.failure as? WriteFailure == .alreadyExists(try ServicePath("one.txt")))
        #expect(contents(destination, "one.txt") == Data("old".utf8))

        let replaced = await run(try request(["one.txt"], mode: .copy, policy: .replace))
        #expect(replaced.succeeded, "\(String(describing: replaced.failure))")
        #expect(contents(destination, "one.txt") == Data("new".utf8))

        // A directory already there is filled, and what it holds is kept.
        let big = plantTree()
        destination.directory("tree")
        destination.file("tree/keep.txt", contents: "kept")
        let merged = await run(try request(["tree"], mode: .copy, policy: .replace))
        #expect(merged.succeeded, "\(String(describing: merged.failure))")
        expectTree(in: destination, under: "tree", big: big)
        #expect(contents(destination, "tree/keep.txt") == Data("kept".utf8))
    }

    @Test("Links are skipped and named, never dereferenced")
    func skipsLinks() async throws {
        let big = plantTree()
        #expect(symlink(source.path("tree/a.txt"), source.path("tree/pointer")) == 0)
        let outcome = await run(try request(["tree"], mode: .copy))
        let shortfall = try #require(outcome.failure as? TransferShortfall)
        #expect(shortfall.skipped == [try ServicePath("tree/pointer")])
        #expect(shortfall.retained.isEmpty)
        expectTree(in: destination, under: "tree", big: big)
        #expect(!names(destination, "tree").contains("pointer"))
    }

    @Test("Refusals are decided before the first byte")
    func refusals() async throws {
        let same = adapter(source)
        source.directory("dir")
        source.file("dir/x.txt")
        let nothing = await run(try request([], mode: .copy))
        #expect(nothing.failure as? TransferRefusal == .nothingToTransfer)
        let conflict = await run(TransferRequest(
            source: TransferSource(backend: BackendID("a"), service: same, paths: [try ServicePath("dir"), try ServicePath("dir")]),
            destination: TransferDestination(backend: BackendID("b"), service: adapter(destination), directory: .root),
            mode: .copy, policy: .failIfExists
        ))
        #expect(conflict.failure as? TransferRefusal == .conflictingNames("dir"))
        let sameLocation = await run(TransferRequest(
            source: TransferSource(backend: BackendID("a"), service: same, paths: [try ServicePath("dir")]),
            destination: TransferDestination(backend: BackendID("a"), service: same, directory: .root),
            mode: .copy, policy: .failIfExists
        ))
        #expect(sameLocation.failure as? TransferRefusal == .sameLocation(try ServicePath("dir")))
        let inside = await run(TransferRequest(
            source: TransferSource(backend: BackendID("a"), service: same, paths: [try ServicePath("dir")]),
            destination: TransferDestination(backend: BackendID("a"), service: same, directory: try ServicePath("dir")),
            mode: .copy, policy: .failIfExists
        ))
        #expect(inside.failure as? TransferRefusal == .insideSource(try ServicePath("dir")))
        #expect(names(destination).isEmpty)
    }

    // MARK: - Moves

    @Test("A moved tree is complete at the destination and gone from the source")
    func movesTree() async throws {
        let big = plantTree()
        source.file("beside.txt", contents: "stays")
        let outcome = await run(try request(["tree"], mode: .move))
        #expect(outcome.succeeded, "\(String(describing: outcome.failure))")
        expectTree(in: destination, under: "tree", big: big)
        #expect(names(source) == ["beside.txt"])
        #expect(outcome.affected.contains(FileLocation(backend: BackendID("a"), path: try ServicePath("tree/sub"))))
    }

    @Test("A source that changed after it was read is copied but kept, and so is every directory above it")
    func changedSourceIsRetained() async throws {
        let big = plantTree()
        let hooked = HookedService(inner: adapter(source))
        // The hook runs off the main actor: it takes the path it touches,
        // not the scratch that owns it.
        let touched = source.path("tree/a.txt")
        hooked.afterOpen = { path in
            guard path.name == "a.txt" else { return }
            var times = [timeval(tv_sec: 1_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000, tv_usec: 0)]
            _ = utimes(touched, &times)
        }
        let outcome = await run(try request(["tree"], mode: .move, source: hooked))
        let shortfall = try #require(outcome.failure as? TransferShortfall)
        #expect(shortfall.retained == [try ServicePath("tree/a.txt"), try ServicePath("tree")])
        expectTree(in: destination, under: "tree", big: big)
        #expect(contents(source, "tree/a.txt") == Data("alpha".utf8), "kept")
        #expect(!names(source, "tree").contains("sub"), "what matched was removed")
        #expect(!names(source, "tree").contains("empty"))
    }

    @Test("A refused removal keeps the copy and reports the source as retained")
    func refusedRemoval() async throws {
        source.file("one.txt", contents: "hello")
        let hooked = HookedService(inner: adapter(source))
        hooked.refuseRemovals = true
        let outcome = await run(try request(["one.txt"], mode: .move, source: hooked))
        let shortfall = try #require(outcome.failure as? TransferShortfall)
        #expect(shortfall.retained == [try ServicePath("one.txt")])
        #expect(contents(destination, "one.txt") == Data("hello".utf8))
        #expect(contents(source, "one.txt") == Data("hello".utf8))
    }

    @Test("A move of links keeps the link and the directory it is in")
    func moveKeepsLinks() async throws {
        let big = plantTree()
        #expect(symlink(source.path("tree/a.txt"), source.path("tree/sub/pointer")) == 0)
        let outcome = await run(try request(["tree"], mode: .move))
        let shortfall = try #require(outcome.failure as? TransferShortfall)
        #expect(shortfall.skipped == [try ServicePath("tree/sub/pointer")])
        #expect(shortfall.retained == [try ServicePath("tree/sub"), try ServicePath("tree")])
        expectTree(in: destination, under: "tree", big: big)
        #expect(names(source, "tree") == ["sub"])
        #expect(names(source, "tree/sub") == ["pointer"])
    }

    @Test("A move without a writable source is refused before anything is copied")
    func moveNeedsWritableSource() async throws {
        source.file("one.txt")
        let outcome = await run(try request(["one.txt"], mode: .move, source: ReadOnlyService(inner: adapter(source))))
        #expect(outcome.failure as? TransferRefusal == .sourceNotWritable)
        #expect(names(destination).isEmpty)
    }

    @Test("A move within one backend is that backend's rename, root by root")
    func sameBackendMove() async throws {
        let big = plantTree()
        source.directory("target")
        let same = adapter(source)
        let outcome = await run(TransferRequest(
            source: TransferSource(backend: BackendID("a"), service: same, paths: [try ServicePath("tree")]),
            destination: TransferDestination(backend: BackendID("a"), service: same, directory: try ServicePath("target")),
            mode: .move, policy: .failIfExists
        ))
        #expect(outcome.succeeded, "\(String(describing: outcome.failure))")
        expectTree(in: source, under: "target/tree", big: big)
        #expect(!names(source).contains("tree"))
        #expect(names(stagingScratch).isEmpty, "nothing was relayed")
    }

    // MARK: - Interruptions

    @Test("A lost publication reply stops the transfer with the name marked uncertain and keeps the source")
    func lostPublication() async throws {
        _ = plantTree()
        let flaky = FlakyDestination(inner: adapter(destination))
        flaky.loseReplyFor = try ServicePath("tree/a.txt")
        let outcome = await run(try request(["tree"], mode: .move, destination: flaky))
        let shortfall = try #require(outcome.failure as? TransferShortfall)
        #expect(shortfall.uncertain == [try ServicePath("tree/a.txt")])
        #expect(shortfall.retained.isEmpty, "nothing was cleaned up")
        #expect(contents(source, "tree/a.txt") == Data("alpha".utf8))
        #expect(names(source, "tree/sub") == ["big.bin"])
    }

    @Test("Cancellation keeps what was published, and leaves no temporary or staging file")
    func cancellation() async throws {
        let huge = Data(count: 48 * LocalFileServiceAdapter.chunkSize)
        source.file("first.txt", contents: "first")
        FileManager.default.createFile(atPath: source.path("huge.bin"), contents: huge)
        let progress = ReportLog()
        let staged = StagedService(inner: adapter(source))
        // Roots are carried in the order given: the small one is published
        // before the large one starts, and the cancel lands inside the large.
        let request = try request(["first.txt", "huge.bin"], mode: .move, source: staged)
        let task = Task {
            await FileTransfer.run(request, staging: staging) { report in
                progress.append(report)
                if report.bytesDone > 4 * Int64(LocalFileServiceAdapter.chunkSize) { progress.cancelOnce?() }
            }
        }
        progress.cancelOnce = { task.cancel() }
        let outcome = await task.value
        #expect(outcome.wasCancelled, "\(String(describing: outcome.failure))")
        #expect(contents(destination, "first.txt") == Data("first".utf8), "published before the cancel")
        #expect(!names(destination).contains("huge.bin"))
        #expect(!names(destination).contains { $0.hasPrefix(".fila-transfer-") })
        #expect(names(stagingScratch).isEmpty)
        #expect(contents(source, "first.txt") == Data("first".utf8), "a cancelled move removes nothing")
        #expect(names(source) == ["first.txt", "huge.bin"])
    }

    @Test("A cancel during a move's cleanup is reported cancelled, never as a success with sources left behind")
    func cancellationDuringCleanup() async throws {
        source.file("one.txt", contents: "one")
        source.file("two.txt", contents: "two")
        let hooked = HookedService(inner: adapter(source))
        let progress = ReportLog()
        let request = try request(["one.txt", "two.txt"], mode: .move, source: hooked)
        let task = Task {
            await FileTransfer.run(request, staging: staging) { progress.append($0) }
        }
        // The first removal goes ahead — the cancel is seen between nodes —
        // and the second is never attempted.
        hooked.beforeRemoval = { _ in progress.cancelOnce?() }
        progress.cancelOnce = { task.cancel() }
        let outcome = await task.value
        #expect(outcome.wasCancelled, "\(String(describing: outcome.failure))")
        #expect(!outcome.succeeded)
        #expect(contents(destination, "one.txt") == Data("one".utf8))
        #expect(contents(destination, "two.txt") == Data("two".utf8))
        #expect(names(source) == ["two.txt"], "the source not reached is still there")
    }

    @Test("Replacing into a link to a directory is refused rather than written through")
    func replaceRefusesLinkedDirectory() async throws {
        source.directory("tree")
        source.file("tree/a.txt", contents: "alpha")
        destination.directory("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: destination.path("tree"), withDestinationPath: "elsewhere")
        let outcome = await run(try request(["tree"], mode: .copy, policy: .replace))
        guard case WriteFailure.alreadyExists(let path)? = outcome.failure else {
            Issue.record("expected alreadyExists, got \(String(describing: outcome.failure))")
            return
        }
        #expect(path == (try ServicePath("tree")))
        #expect(names(destination, "elsewhere").isEmpty, "nothing was written where the link points")
    }

    @Test("A source that grew before it was read is copied whole, and a move keeps it")
    func grownSourceIsCopiedWhole() async throws {
        source.file("log.txt", contents: "line one\n")
        let hooked = HookedService(inner: adapter(source))
        let appended = source.path("log.txt")
        hooked.afterOpen = { path in
            guard path.name == "log.txt" else { return }
            let handle = FileHandle(forWritingAtPath: appended)
            handle?.seekToEndOfFile()
            handle?.write(Data("line two\n".utf8))
            try? handle?.close()
        }
        let copy = await run(try request(["log.txt"], mode: .copy, source: hooked))
        #expect(copy.succeeded, "\(String(describing: copy.failure))")
        #expect(contents(destination, "log.txt") == Data("line one\nline two\n".utf8))

        let move = await run(try request(["log.txt"], mode: .move, policy: .replace, source: hooked))
        let shortfall = try #require(move.failure as? TransferShortfall)
        #expect(shortfall.retained == [try ServicePath("log.txt")])
        #expect(contents(source, "log.txt") == Data("line one\nline two\nline two\n".utf8), "kept")
    }
}

// MARK: - Wrappers

final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgressReport] = []
    private var once: (@Sendable () -> Void)?
    func append(_ report: TransferProgressReport) { lock.lock(); log.append(report); lock.unlock() }
    var reports: [TransferProgressReport] { lock.lock(); defer { lock.unlock() }; return log }
    var cancelOnce: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; defer { once = nil }; return once }
        set { lock.lock(); once = newValue; lock.unlock() }
    }
}

/// The adapter with hooks: what a remote can do between a read and a
/// removal.
final class HookedService: WritableFileService, DescriptorFileService, @unchecked Sendable {
    let inner: LocalFileServiceAdapter
    var afterOpen: (@Sendable (ServicePath) -> Void)?
    var beforeRemoval: (@Sendable (ServicePath) -> Void)?
    var refuseRemovals = false
    struct Refused: Error {}

    init(inner: LocalFileServiceAdapter) { self.inner = inner }

    func list(_ directory: ServicePath) async throws -> FileListing { try await inner.list(directory) }
    func details(_ path: ServicePath) async throws -> FileEntry { try await inner.details(path) }
    func copyContents(of path: ServicePath, to descriptor: Int32, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.copyContents(of: path, to: descriptor, progress: progress)
    }
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> { try await inner.changes(in: directory) }
    func openForReading(_ path: ServicePath) async throws -> Int32 {
        let descriptor = try await inner.openForReading(path)
        afterOpen?(path)
        return descriptor
    }
    func createDirectory(_ directory: ServicePath) async throws { try await inner.createDirectory(directory) }
    func writeFile(from descriptor: Int32, size: Int64, to destination: ServicePath, policy: PublishPolicy, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.writeFile(from: descriptor, size: size, to: destination, policy: policy, progress: progress)
    }
    func removeFile(_ path: ServicePath) async throws {
        if refuseRemovals { throw Refused() }
        beforeRemoval?(path)
        try await inner.removeFile(path)
    }
    func removeEmptyDirectory(_ path: ServicePath) async throws {
        if refuseRemovals { throw Refused() }
        try await inner.removeEmptyDirectory(path)
    }
    func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        try await inner.move(source, to: destination, policy: policy)
    }
}

/// The adapter without its descriptor: a source that must be staged, as
/// every remote is.
final class StagedService: WritableFileService, @unchecked Sendable {
    let inner: LocalFileServiceAdapter
    init(inner: LocalFileServiceAdapter) { self.inner = inner }
    func list(_ directory: ServicePath) async throws -> FileListing { try await inner.list(directory) }
    func details(_ path: ServicePath) async throws -> FileEntry { try await inner.details(path) }
    func copyContents(of path: ServicePath, to descriptor: Int32, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.copyContents(of: path, to: descriptor, progress: progress)
    }
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> { try await inner.changes(in: directory) }
    func createDirectory(_ directory: ServicePath) async throws { try await inner.createDirectory(directory) }
    func writeFile(from descriptor: Int32, size: Int64, to destination: ServicePath, policy: PublishPolicy, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.writeFile(from: descriptor, size: size, to: destination, policy: policy, progress: progress)
    }
    func removeFile(_ path: ServicePath) async throws { try await inner.removeFile(path) }
    func removeEmptyDirectory(_ path: ServicePath) async throws { try await inner.removeEmptyDirectory(path) }
    func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        try await inner.move(source, to: destination, policy: policy)
    }
}

/// A source that can only be read.
final class ReadOnlyService: FileService, @unchecked Sendable {
    let inner: LocalFileServiceAdapter
    init(inner: LocalFileServiceAdapter) { self.inner = inner }
    func list(_ directory: ServicePath) async throws -> FileListing { try await inner.list(directory) }
    func details(_ path: ServicePath) async throws -> FileEntry { try await inner.details(path) }
    func copyContents(of path: ServicePath, to descriptor: Int32, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.copyContents(of: path, to: descriptor, progress: progress)
    }
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> { try await inner.changes(in: directory) }
}

/// A destination whose publication reply for one name never comes back —
/// after the file was in fact published, as a server that answered into a
/// dead connection would have.
final class FlakyDestination: WritableFileService, @unchecked Sendable {
    let inner: LocalFileServiceAdapter
    var loseReplyFor: ServicePath?
    init(inner: LocalFileServiceAdapter) { self.inner = inner }
    func list(_ directory: ServicePath) async throws -> FileListing { try await inner.list(directory) }
    func details(_ path: ServicePath) async throws -> FileEntry { try await inner.details(path) }
    func copyContents(of path: ServicePath, to descriptor: Int32, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.copyContents(of: path, to: descriptor, progress: progress)
    }
    func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> { try await inner.changes(in: directory) }
    func createDirectory(_ directory: ServicePath) async throws { try await inner.createDirectory(directory) }
    func writeFile(from descriptor: Int32, size: Int64, to destination: ServicePath, policy: PublishPolicy, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await inner.writeFile(from: descriptor, size: size, to: destination, policy: policy, progress: progress)
        if destination == loseReplyFor { throw WriteFailure.publicationUnknown(destination) }
    }
    func removeFile(_ path: ServicePath) async throws { try await inner.removeFile(path) }
    func removeEmptyDirectory(_ path: ServicePath) async throws { try await inner.removeEmptyDirectory(path) }
    func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws {
        try await inner.move(source, to: destination, policy: policy)
    }
}
