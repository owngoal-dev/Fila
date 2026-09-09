import Darwin
import FilaBackendKit
@testable import FilaClient
@testable import FilaSMB
import Foundation
import Testing

/// The share as a transfer destination and source, against the same live
/// server `SMBLiveServerTests` uses and skipped without it. Every check
/// reads the fixtures directory the share exports, so what the server
/// holds is verified on disk rather than through the protocol that wrote
/// it.
@Suite("SMB live writing", .serialized)
struct SMBLiveWritingTests {
    typealias Server = SMBLiveServerTests.Server

    private func withFixture(_ server: Server, _ body: (String, URL) async throws -> Void) async throws {
        let name = "write-" + UUID().uuidString.prefix(8)
        let directory = server.fixtures.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(name, directory)
    }

    private func localFile(_ contents: Data) throws -> (Int32, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smb-upload-" + UUID().uuidString)
        try contents.write(to: url)
        let descriptor = open(url.path, O_RDONLY)
        try #require(descriptor >= 0)
        return (descriptor, url)
    }

    private func names(_ directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    @Test("A file is uploaded in chunks, published exclusively, and replaced only when asked")
    func writeFile() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let service = server.service()
            let size = 5 * Int(SMBFileService.writeChunk) + 321
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                for index in stride(from: 0, to: size, by: 1024) { buffer[index] = UInt8(truncatingIfNeeded: index / 1024) }
            }
            let (descriptor, local) = try localFile(payload)
            defer { close(descriptor); try? FileManager.default.removeItem(at: local) }
            let progress = ProgressLog()
            let target = try ServicePath("\(name)/uploaded.bin")
            try await service.writeFile(from: descriptor, size: Int64(size), to: target, policy: .failIfExists) { progress.append($0) }
            #expect(try Data(contentsOf: directory.appendingPathComponent("uploaded.bin")) == payload)
            #expect(progress.reports.last?.completed == Int64(size))
            #expect(progress.reports.count > 5, "many one-megabyte writes")
            #expect(!names(directory).contains { $0.hasPrefix(".fila-transfer-") })
            let published = try await service.details(target)
            #expect(published.size == Int64(size))

            // Occupied: the server refuses in the rename, the original stays.
            let (again, againURL) = try localFile(Data("other".utf8))
            defer { close(again); try? FileManager.default.removeItem(at: againURL) }
            await #expect(throws: WriteFailure.alreadyExists(target)) {
                try await service.writeFile(from: again, size: 5, to: target, policy: .failIfExists) { _ in }
            }
            #expect(try Data(contentsOf: directory.appendingPathComponent("uploaded.bin")) == payload)
            #expect(!names(directory).contains { $0.hasPrefix(".fila-transfer-") })

            // Replacing: the server's one rename.
            let (third, thirdURL) = try localFile(Data("other".utf8))
            defer { close(third); try? FileManager.default.removeItem(at: thirdURL) }
            try await service.writeFile(from: third, size: 5, to: target, policy: .replace) { _ in }
            #expect(try Data(contentsOf: directory.appendingPathComponent("uploaded.bin")) == Data("other".utf8))
            #expect(names(directory) == ["uploaded.bin"])

            // An empty file is a file.
            let (empty, emptyURL) = try localFile(Data())
            defer { close(empty); try? FileManager.default.removeItem(at: emptyURL) }
            try await service.writeFile(from: empty, size: 0, to: try ServicePath("\(name)/empty"), policy: .failIfExists) { _ in }
            #expect(try Data(contentsOf: directory.appendingPathComponent("empty")).isEmpty)
            await service.disconnect()
        }
    }

    @Test("A cancelled upload leaves neither the name nor a temporary on the share")
    func cancelledUpload() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let service = server.service()
            let (descriptor, local) = try localFile(Data(count: 64 * 1024 * 1024))
            defer { close(descriptor); try? FileManager.default.removeItem(at: local) }
            let progress = ProgressLog()
            let upload = Task {
                try await service.writeFile(from: descriptor, size: 64 * 1024 * 1024, to: try ServicePath("\(name)/big"), policy: .failIfExists) {
                    progress.append($0)
                }
            }
            while progress.reports.count < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
            upload.cancel()
            let outcome = await upload.result
            switch outcome {
            case .success: Issue.record("a cancelled upload completed")
            case let .failure(error):
                #expect(error is CancellationError || (error as? SMBError) == .disconnected, "got \(error)")
            }
            // The detached cleanup reconnects to remove the temporary.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(names(directory).isEmpty, "\(names(directory))")
            await service.disconnect()
        }
    }

    @Test("Directories are created, one node is removed at a time, and a full directory is refused")
    func directoriesAndRemovals() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let service = server.service()
            let made = try ServicePath("\(name)/made")
            try await service.createDirectory(made)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("made").path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            await #expect(throws: WriteFailure.alreadyExists(made)) {
                try await service.createDirectory(made)
            }
            FileManager.default.createFile(atPath: directory.appendingPathComponent("made/inside.txt").path, contents: Data("x".utf8))
            await #expect(throws: WriteFailure.notEmpty(made)) {
                try await service.removeEmptyDirectory(made)
            }
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("made/inside.txt").path), "nothing inside was touched")
            try await service.removeFile(try ServicePath("\(name)/made/inside.txt"))
            try await service.removeEmptyDirectory(made)
            #expect(names(directory).isEmpty)
            await #expect(throws: WriteFailure.notFound(made)) {
                try await service.removeEmptyDirectory(made)
            }
            await service.disconnect()
        }
    }

    @Test("A rename on the share is exclusive unless asked to replace")
    func move() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let service = server.service()
            FileManager.default.createFile(atPath: directory.appendingPathComponent("a.txt").path, contents: Data("a".utf8))
            FileManager.default.createFile(atPath: directory.appendingPathComponent("b.txt").path, contents: Data("b".utf8))
            let a = try ServicePath("\(name)/a.txt")
            let b = try ServicePath("\(name)/b.txt")
            await #expect(throws: WriteFailure.alreadyExists(b)) {
                try await service.move(a, to: b, policy: .failIfExists)
            }
            #expect(try Data(contentsOf: directory.appendingPathComponent("b.txt")) == Data("b".utf8))
            try await service.move(a, to: b, policy: .replace)
            #expect(try Data(contentsOf: directory.appendingPathComponent("b.txt")) == Data("a".utf8))
            #expect(names(directory) == ["b.txt"])
            await #expect(throws: WriteFailure.notFound(a)) {
                try await service.move(a, to: try ServicePath("\(name)/c.txt"), policy: .failIfExists)
            }
            await service.disconnect()
        }
    }

    @Test("A tree moves from a local root to the share and back, complete at each end")
    @MainActor
    func roundTrip() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let local = LocalScratchRoot()
            let staging = LocalScratchRoot()
            let big = Data((0 ..< (2 * Int(SMBFileService.writeChunk) + 77)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
            local.directory("tree/sub")
            local.directory("tree/empty")
            local.file("tree/α β.txt", contents: Data("alpha".utf8))
            local.file("tree/sub/big.bin", contents: big)
            let localService = LocalFileServiceAdapter(access: LocalFileService(), rootPath: local.root, observation: DirectoryObservation())
            let remote = server.service()
            let toShare = TransferRequest(
                source: TransferSource(backend: BackendID("local"), service: localService, paths: [try ServicePath("tree")]),
                destination: TransferDestination(backend: BackendID("smb"), service: remote, directory: try ServicePath(name)),
                mode: .move, policy: .failIfExists
            )
            let progress = ProgressLog2()
            let up = await FileTransfer.run(toShare, staging: staging.url) { progress.append($0) }
            #expect(up.succeeded, "\(String(describing: up.failure))")
            #expect(try Data(contentsOf: directory.appendingPathComponent("tree/α β.txt")) == Data("alpha".utf8))
            #expect(try Data(contentsOf: directory.appendingPathComponent("tree/sub/big.bin")) == big)
            #expect(names(directory.appendingPathComponent("tree/empty")).isEmpty)
            #expect(names(directory.appendingPathComponent("tree")) == ["α β.txt", "sub", "empty"])
            #expect(local.names().isEmpty, "the move removed the local tree")
            let last = try #require(progress.reports.last)
            #expect(last.bytesTotal == Int64(big.count + 5), "one leg: the local source hands out a descriptor")
            #expect(last.bytesDone == last.bytesTotal)

            // And back: the share is staged, two legs per file.
            let toLocal = TransferRequest(
                source: TransferSource(backend: BackendID("smb"), service: remote, paths: [try ServicePath("\(name)/tree")]),
                destination: TransferDestination(backend: BackendID("local"), service: localService, directory: .root),
                mode: .move, policy: .failIfExists
            )
            let back = ProgressLog2()
            let down = await FileTransfer.run(toLocal, staging: staging.url) { back.append($0) }
            #expect(down.succeeded, "\(String(describing: down.failure))")
            #expect(FileManager.default.contents(atPath: local.path("tree/α β.txt")) == Data("alpha".utf8))
            #expect(FileManager.default.contents(atPath: local.path("tree/sub/big.bin")) == big)
            #expect(local.names("tree/empty").isEmpty)
            #expect(names(directory).isEmpty, "the move removed the share's tree")
            #expect(back.reports.last?.bytesTotal == 2 * Int64(big.count + 5))
            #expect(staging.names().isEmpty)
            await remote.disconnect()
        }
    }
}

final class ProgressLog2: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgressReport] = []
    func append(_ report: TransferProgressReport) { lock.lock(); log.append(report); lock.unlock() }
    var reports: [TransferProgressReport] { lock.lock(); defer { lock.unlock() }; return log }
}

/// A local directory for one test, gone with it.
final class LocalScratchRoot {
    let root: String
    var url: URL { URL(fileURLWithPath: root, isDirectory: true) }

    init() {
        root = "/private/tmp/fila-smb-tests-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
        precondition(mkdir(root, 0o755) == 0)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    func directory(_ relative: String) {
        precondition((try? FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)) != nil)
    }

    func file(_ relative: String, contents: Data) {
        precondition(FileManager.default.createFile(atPath: path(relative), contents: contents))
    }

    func names(_ relative: String = "") -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? root : path(relative))) ?? [])
    }
}
