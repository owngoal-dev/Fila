import Darwin
import FilaBackendKit
@testable import FilaClient
@testable import FilaProtocol
import Foundation
import Testing

/// The local adapter as a transfer destination: every write is the guarded
/// one, published in one step, and every removal is one node.
@Suite("Local writable service")
@MainActor
struct LocalWritableServiceTests {
    let scratch = LocalScratch()

    private func adapter() -> LocalFileServiceAdapter {
        LocalFileServiceAdapter(access: LocalFileService(), rootPath: scratch.root, observation: DirectoryObservation())
    }

    private func source(_ contents: Data) throws -> Int32 {
        let path = scratch.path("source-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: path, contents: contents)
        let descriptor = Darwin.open(path, O_RDONLY)
        try #require(descriptor >= 0)
        return descriptor
    }

    private func names(in relative: String = "") -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? scratch.root : scratch.path(relative))) ?? [])
    }

    @Test
    func `A directory is created with the item defaults, and a taken name is refused`() async throws {
        let service = adapter()
        try await service.createDirectory(ServicePath("made"))
        var status = stat()
        #expect(lstat(scratch.path("made"), &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFDIR)
        #expect(status.st_mode & 0o7777 == 0o777)
        await #expect(throws: try WriteFailure.alreadyExists(ServicePath("made"))) {
            try await service.createDirectory(ServicePath("made"))
        }
    }

    @Test
    func `A file is written beside its name and published exclusively, leaving no temporary`() async throws {
        let service = adapter()
        let payload = Data((0 ..< (LocalFileServiceAdapter.chunkSize + 3)).map { UInt8(truncatingIfNeeded: $0) })
        let descriptor = try source(payload)
        defer { close(descriptor) }
        let progress = WriteProgressLog()
        try await service.writeFile(from: descriptor, size: Int64(payload.count), to: ServicePath("out.bin"), policy: .failIfExists) {
            progress.append($0)
        }
        #expect(FileManager.default.contents(atPath: scratch.path("out.bin")) == payload)
        #expect(progress.reports.last?.completed == Int64(payload.count))
        #expect(!names().contains { $0.hasPrefix(".fila-transfer-") })
        var status = stat()
        #expect(lstat(scratch.path("out.bin"), &status) == 0)
        #expect(status.st_mode & 0o7777 == 0o777, "new item defaults")

        // Occupied: refused, the original untouched, no temporary left.
        let again = try source(Data("other".utf8))
        defer { close(again) }
        await #expect(throws: try WriteFailure.alreadyExists(ServicePath("out.bin"))) {
            try await service.writeFile(from: again, size: 5, to: ServicePath("out.bin"), policy: .failIfExists) { _ in }
        }
        #expect(FileManager.default.contents(atPath: scratch.path("out.bin")) == payload)
        #expect(!names().contains { $0.hasPrefix(".fila-transfer-") })
    }

    @Test
    func `Replacing keeps the original's mode and refuses a directory at the name`() async throws {
        let service = adapter()
        scratch.file("old.txt", contents: "stale")
        chmod(scratch.path("old.txt"), 0o640)
        let descriptor = try source(Data("fresh".utf8))
        defer { close(descriptor) }
        try await service.writeFile(from: descriptor, size: 5, to: ServicePath("old.txt"), policy: .replace) { _ in }
        #expect(FileManager.default.contents(atPath: scratch.path("old.txt")) == Data("fresh".utf8))
        var status = stat()
        #expect(lstat(scratch.path("old.txt"), &status) == 0)
        #expect(status.st_mode & 0o7777 == 0o640)

        scratch.directory("folder")
        let second = try source(Data("x".utf8))
        defer { close(second) }
        await #expect(throws: try WriteFailure.notEmpty(ServicePath("folder"))) {
            try await service.writeFile(from: second, size: 1, to: ServicePath("folder"), policy: .replace) { _ in }
        }
        #expect(names().contains("folder"))
        #expect(!names().contains { $0.hasPrefix(".fila-transfer-") })
    }

    @Test
    func `A cancelled write leaves nothing at the name and no temporary`() async throws {
        let service = adapter()
        let payload = Data(count: 24 * LocalFileServiceAdapter.chunkSize)
        let descriptor = try source(payload)
        defer { close(descriptor) }
        let progress = WriteProgressLog()
        let task = Task {
            try await service.writeFile(from: descriptor, size: Int64(payload.count), to: ServicePath("big.bin"), policy: .failIfExists) {
                progress.append($0)
                if progress.reports.count == 2 {
                    progress.cancelOnce?()
                }
            }
        }
        progress.cancelOnce = { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!names().contains("big.bin"))
        #expect(!names().contains { $0.hasPrefix(".fila-transfer-") })
    }

    @Test
    func `Removal takes one node of the verified kind and refuses a full directory`() async throws {
        let service = adapter()
        scratch.directory("dir")
        scratch.file("dir/a.txt")
        await #expect(throws: try WriteFailure.notEmpty(ServicePath("dir"))) {
            try await service.removeEmptyDirectory(ServicePath("dir"))
        }
        try await service.removeFile(ServicePath("dir/a.txt"))
        try await service.removeEmptyDirectory(ServicePath("dir"))
        #expect(!names().contains("dir"))
        await #expect(throws: try WriteFailure.notFound(ServicePath("dir"))) {
            try await service.removeEmptyDirectory(ServicePath("dir"))
        }
    }

    @Test
    func `A move is a rename, exclusive unless asked to replace`() async throws {
        let service = adapter()
        scratch.file("a.txt", contents: "a")
        scratch.file("b.txt", contents: "b")
        await #expect(throws: try WriteFailure.alreadyExists(ServicePath("b.txt"))) {
            try await service.move(ServicePath("a.txt"), to: ServicePath("b.txt"), policy: .failIfExists)
        }
        #expect(FileManager.default.contents(atPath: scratch.path("b.txt")) == Data("b".utf8))
        try await service.move(ServicePath("a.txt"), to: ServicePath("b.txt"), policy: .replace)
        #expect(FileManager.default.contents(atPath: scratch.path("b.txt")) == Data("a".utf8))
        #expect(!names().contains("a.txt"))
        await #expect(throws: try WriteFailure.notFound(ServicePath("a.txt"))) {
            try await service.move(ServicePath("a.txt"), to: ServicePath("c.txt"), policy: .failIfExists)
        }
    }

    @Test
    func `A read descriptor is handed out for a file only`() async throws {
        let service = adapter()
        scratch.file("plain.txt", contents: "hello")
        let descriptor = try await service.openForReading(ServicePath("plain.txt"))
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(read(descriptor, &buffer, 8) == 5)
        close(descriptor)
        scratch.directory("folder")
        let failure = await #expect(throws: FilaFailure.self) {
            _ = try await service.openForReading(ServicePath("folder"))
        }
        #expect(failure?.systemError == EISDIR)
    }
}

final class WriteProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgress] = []
    private var once: (@Sendable () -> Void)?
    func append(_ progress: TransferProgress) {
        lock.lock(); log.append(progress); lock.unlock()
    }

    var reports: [TransferProgress] {
        lock.lock(); defer { lock.unlock() }; return log
    }

    /// A hook fired by the caller once, then cleared.
    var cancelOnce: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; defer { once = nil }; return once }
        set { lock.lock(); once = newValue; lock.unlock() }
    }
}
