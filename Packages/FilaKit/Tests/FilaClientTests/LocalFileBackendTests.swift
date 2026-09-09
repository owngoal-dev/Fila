import CRemoveFile
import Darwin
import FilaBackendKit
@testable import FilaClient
import FilaLog
import FilaProtocol
import Foundation
import Testing

/// The two local backends against one contract.
///
/// Every test runs against the full backend rooted at a scratch directory
/// and against the sandboxed backend given that directory as its Documents,
/// because the promise is that they behave the same — the sandboxed one only
/// starts somewhere else and can hold nothing but in-process access.
@Suite("Local file backends")
@MainActor
struct LocalFileBackendTests {
    let scratch = LocalScratch()

    private func backends() -> [(String, LocalFileBackend)] {
        [
            ("full", LocalFileBackend(access: LocalFileService(), rootPath: scratch.root, displayName: "Scratch", symbolName: "folder")),
            ("sandboxed", SandboxedLocalFileBackend(documents: URL(fileURLWithPath: scratch.root, isDirectory: true))),
        ]
    }

    @Test("Both backends share one identity and resolve paths under their root")
    func identity() throws {
        for (_, backend) in backends() {
            #expect(backend.id == LocalFileBackend.identifier)
            #expect(backend.root.location == .root(of: LocalFileBackend.identifier))
            #expect(backend.root.kind == .filesystem)
            #expect(backend.absolutePath(.root) == scratch.root)
            #expect(backend.absolutePath(try ServicePath("a/b")) == scratch.root + "/a/b")
        }
        #expect(LocalFileBackend(access: LocalFileService()).absolutePath(try ServicePath("var")) == "/var")
    }

    @Test("The sandboxed backend starts at Documents and holds in-process access")
    func sandboxedAuthority() {
        let backend = SandboxedLocalFileBackend(documents: URL(fileURLWithPath: scratch.root, isDirectory: true))
        #expect(backend.rootPath == scratch.root)
        #expect(backend.access is LocalFileService)
        // Resolved at construction, not stored: the default is this process's
        // own Documents directory, wherever the container is today.
        #expect(SandboxedLocalFileBackend().rootPath.hasSuffix("/Documents"))
    }

    @Test("Lists a directory in pages and releases the cursor when abandoned")
    func listing() async throws {
        for index in 0 ... FilaProtocol.directoryPageEntryCount { scratch.file("entry-\(index)") }
        for (name, backend) in backends() {
            let service = try await backend.fileService()
            var names: [String] = []
            var batches = 0
            for try await batch in try await service.list(.root) {
                names += batch.map(\.name)
                batches += 1
            }
            #expect(batches == 2, "\(name)")
            #expect(names.count == FilaProtocol.directoryPageEntryCount + 1, "\(name)")
        }
    }

    @Test("An abandoned listing closes its cursor once; a finished or unstarted one closes nothing")
    func cursorRelease() async throws {
        for index in 0 ... FilaProtocol.directoryPageEntryCount { scratch.file("entry-\(index)") }
        let spy = RecordingAccess(LocalFileService())
        let backend = LocalFileBackend(access: spy, rootPath: scratch.root, displayName: "Scratch", symbolName: "folder")
        let service = try await backend.fileService()

        // Stopped after the first page: the release must close exactly the
        // cursor that page handed back.
        do {
            var iterator = try await service.list(.root).makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.count == FilaProtocol.directoryPageEntryCount)
        }
        try await spy.settled()
        #expect(spy.closed == [spy.lastCursor])

        // Never asked for a page: nothing to close.
        do { _ = try await service.list(.root).makeAsyncIterator() }
        try await spy.settled()
        #expect(spy.closed.count == 1)

        // Read to the end: the last page released the cursor already.
        for try await _ in try await service.list(.root) {}
        try await spy.settled()
        #expect(spy.closed.count == 1)

        // Two iterators of one listing are two cursors.
        let listing = try await service.list(.root)
        var a = listing.makeAsyncIterator()
        var b = listing.makeAsyncIterator()
        _ = try await a.next()
        _ = try await b.next()
        #expect(Set(spy.opened.suffix(2)).count == 2)
        _ = try await a.next()
        _ = try await b.next()
        #expect(try await a.next() == nil)
        #expect(try await b.next() == nil)
    }

    @Test("Details and entry kinds come from the node, without invented metadata")
    func details() async throws {
        scratch.file("plain", contents: "12345")
        scratch.directory("dir")
        symlink("plain", scratch.path("link"))
        symlink("missing", scratch.path("broken"))
        for (name, backend) in backends() {
            let service = try await backend.fileService()
            let plain = try await service.details(try ServicePath("plain"))
            #expect(plain.kind == .file && plain.size == 5 && plain.modified != nil, "\(name)")
            let dir = try await service.details(try ServicePath("dir"))
            #expect(dir.kind == .directory && dir.size == nil && dir.entersDirectory, "\(name)")
            let link = try await service.details(try ServicePath("link"))
            #expect(link.kind == .symbolicLink(resolved: .file), "\(name)")
            let broken = try await service.details(try ServicePath("broken"))
            #expect(broken.kind == .symbolicLink(resolved: nil), "\(name)")
            await #expect(throws: FilaFailure.self, "\(name)") {
                _ = try await service.details(try ServicePath("absent"))
            }
        }
    }

    @Test("copyContents fills the caller's descriptor, reports progress and closes only its source")
    func copyContents() async throws {
        let payload = Data((0 ..< (3 * LocalFileServiceAdapter.chunkSize + 17)).map { UInt8(truncatingIfNeeded: $0) })
        FileManager.default.createFile(atPath: scratch.path("big"), contents: payload)
        for (name, backend) in backends() {
            let service = try await backend.fileService()
            let staging = scratch.path("staging-\(name)")
            let output = Darwin.open(staging, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            #expect(output >= 0)
            let progress = ProgressLog()
            try await service.copyContents(of: try ServicePath("big"), to: output) { progress.append($0) }
            // Still ours to close: the adapter did not.
            #expect(fcntl(output, F_GETFD) != -1, "\(name)")
            close(output)
            #expect(FileManager.default.contents(atPath: staging) == payload, "\(name)")
            let reports = progress.reports
            #expect(reports.last == TransferProgress(completed: Int64(payload.count), expected: Int64(payload.count)), "\(name)")
            #expect(reports.map(\.completed) == reports.map(\.completed).sorted(), "\(name)")
        }
    }

    @Test("A copy cancelled mid-way stops, throws cancellation and leaves the descriptor to its owner")
    func cancelledCopy() async throws {
        let payload = Data(count: 16 * LocalFileServiceAdapter.chunkSize)
        FileManager.default.createFile(atPath: scratch.path("big"), contents: payload)
        let backend = backends()[0].1
        let service = try await backend.fileService()
        let output = Darwin.open(scratch.path("staging"), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer { close(output) }
        let progress = ProgressLog()
        let task = Task {
            try await service.copyContents(of: try ServicePath("big"), to: output) { report in
                progress.append(report)
                // Cancel from inside the pump, after the first chunk landed.
                progress.cancelOnce?()
            }
        }
        progress.cancelOnce = { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        // It stopped well short of the whole file, and the descriptor is
        // still ours.
        #expect(progress.reports.last!.completed < Int64(payload.count))
        #expect(fcntl(output, F_GETFD) != -1)
    }

    @Test("copyContents refuses what is not a regular file and follows a link to its target's size")
    func copySources() async throws {
        scratch.directory("dir")
        scratch.file("plain", contents: "12345")
        symlink("plain", scratch.path("link"))
        let service = try await backends()[0].1.fileService()
        let output = Darwin.open(scratch.path("staging"), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer { close(output) }
        let failure = await #expect(throws: FilaFailure.self) {
            try await service.copyContents(of: try ServicePath("dir"), to: output) { _ in }
        }
        #expect(failure?.systemError == EISDIR)
        let log = ProgressLog()
        try await service.copyContents(of: try ServicePath("link"), to: output) { log.append($0) }
        #expect(log.reports.last == TransferProgress(completed: 5, expected: 5))
    }
}

/// A local access that records cursor traffic and passes everything else on.
private final class RecordingAccess: LocalFileAccess, @unchecked Sendable {
    private let inner: LocalFileService
    private let lock = NSLock()
    private var openedCursors: [UInt64] = []
    private var closedCursors: [UInt64] = []

    init(_ inner: LocalFileService) { self.inner = inner }

    var opened: [UInt64] { lock.lock(); defer { lock.unlock() }; return openedCursors }
    var closed: [UInt64] { lock.lock(); defer { lock.unlock() }; return closedCursors }
    var lastCursor: UInt64 { opened.last ?? 0 }

    /// Releases run on a detached task after an iterator is dropped; give
    /// them a moment, bounded.
    func settled() async throws {
        for _ in 0 ..< 50 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    var jobEvents: AsyncStream<JobUpdate> { inner.jobEvents }
    var searchResults: AsyncStream<SearchUpdate> { inner.searchResults }
    var onLinkLost: (@Sendable () -> Void)? {
        get { inner.onLinkLost }
        set { inner.onLinkLost = newValue }
    }

    func hello() async throws -> LocalHello { try await inner.hello() }
    func list(directory: String, cursor: UInt64) async throws -> DirectoryPage {
        let page = try await inner.list(directory: directory, cursor: cursor)
        if !page.isFinal {
            lock.lock(); openedCursors.append(page.cursor); lock.unlock()
        }
        return page
    }

    func closeDirectory(cursor: UInt64) async throws {
        lock.lock(); closedCursors.append(cursor); lock.unlock()
        try await inner.closeDirectory(cursor: cursor)
    }

    func details(of path: String) async throws -> FileDetails { try await inner.details(of: path) }
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 { try await inner.open(path, flags: flags, mode: mode) }
    func create(_ template: NodeTemplate, at path: String, mode: mode_t?) async throws { try await inner.create(template, at: path, mode: mode) }
    func rename(_ source: String, to destination: String, exclusive: Bool, overrideGuard: Bool) async throws {
        try await inner.rename(source, to: destination, exclusive: exclusive, overrideGuard: overrideGuard)
    }
    func setAttributes(_ change: AttributeChange, at path: String) async throws { try await inner.setAttributes(change, at: path) }
    func replaceItem(at target: String, withTemporary temporary: String) async throws { try await inner.replaceItem(at: target, withTemporary: temporary) }
    func mountPoints() async throws -> [MountPoint] { try await inner.mountPoints() }
    func volumeInfo(for path: String) async throws -> VolumeInfo { try await inner.volumeInfo(for: path) }
    func extendedAttribute(_ name: String, at path: String) async throws -> Data { try await inner.extendedAttribute(name, at: path) }
    func startJob(_ job: JobRequest) async throws -> UInt64 { try await inner.startJob(job) }
    func cancelJob(_ identifier: UInt64) async throws { try await inner.cancelJob(identifier) }
    func fetchLog(since sequence: UInt64, level: FilaLog.Level) async throws -> (records: [FilaLog.Record], dropped: UInt64) {
        try await inner.fetchLog(since: sequence, level: level)
    }
    func invalidate() { inner.invalidate() }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgress] = []
    private var once: (@Sendable () -> Void)?
    func append(_ progress: TransferProgress) { lock.lock(); log.append(progress); lock.unlock() }
    var reports: [TransferProgress] { lock.lock(); defer { lock.unlock() }; return log }
    /// A hook fired by the first report only, then cleared.
    var cancelOnce: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; defer { once = nil }; return once }
        set { lock.lock(); once = newValue; lock.unlock() }
    }
}
