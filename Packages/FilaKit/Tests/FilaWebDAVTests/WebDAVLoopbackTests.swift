import Darwin
import FilaBackendKit
@testable import FilaClient
import FilaRemote
@testable import FilaWebDAV
import Foundation
import Testing

/// Fila's own WebDAV server on loopback over a scratch directory, and the
/// client pointed at it. Every check reads the scratch directory, so what
/// the server holds is verified on disk rather than through the protocol
/// that wrote it.
final class LoopbackServer {
    let scratch = Scratch()
    let server = WebDAVServer(service: LocalService())
    let port: UInt16
    let user = "fila"
    let password = "s3cret"

    init() async throws {
        try server.start(.init(
            port: 0, username: user, password: password, root: scratch.root, advertisesBonjour: false,
        ))
        var found: UInt16?
        for _ in 0 ..< 200 {
            if case let .running(port) = server.status {
                found = port
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        port = try #require(found)
    }

    deinit { server.stop() }

    func profile(password _: String? = nil, path: String = "") -> WebDAVProfile {
        WebDAVProfile(name: "", address: "http://127.0.0.1:\(port)/\(path)", username: user)
    }

    func service(password: String? = nil) -> WebDAVFileService {
        WebDAVFileService(profile: profile(), password: password ?? self.password, pollInterval: 60, requestTimeout: 15)!
    }

    func names(_ relative: String = "") -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.path(relative))) ?? [])
    }

    func data(_ relative: String) -> Data? {
        FileManager.default.contents(atPath: scratch.path(relative))
    }
}

/// A local file open for reading, removed with the test.
private func localFile(_ contents: Data) throws -> (Int32, URL) {
    let url = URL(fileURLWithPath: "/private/tmp/fila-webdav-upload-" + UUID().uuidString)
    try contents.write(to: url)
    let descriptor = open(url.path, O_RDONLY)
    try #require(descriptor >= 0)
    return (descriptor, url)
}

private func pattern(_ size: Int) -> Data {
    Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 10) })
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgress] = []
    func append(_ report: TransferProgress) {
        lock.lock(); log.append(report); lock.unlock()
    }

    var all: [TransferProgress] {
        lock.lock(); defer { lock.unlock() }; return log
    }
}

@Suite("WebDAV loopback", .serialized)
struct WebDAVLoopbackTests {
    @Test
    func `A folder lists its children, not itself, with sizes and kinds`() async throws {
        let loopback = try await LoopbackServer()
        loopback.scratch.directory("docs")
        loopback.scratch.file("docs/a b.txt", contents: "hello")
        loopback.scratch.file("docs/100% ?#;.txt", contents: "x")
        loopback.scratch.file("docs/.hidden", contents: "")
        loopback.scratch.directory("docs/文件夹")
        let service = loopback.service()
        var entries: [FileEntry] = []
        for try await batch in try await service.list(ServicePath("docs")) {
            entries += batch
        }
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a b.txt", "100% ?#;.txt", ".hidden", "文件夹"])
        #expect(byName["a b.txt"]?.size == 5)
        #expect(byName["a b.txt"]?.kind == .file)
        #expect(byName["a b.txt"]?.modified != nil)
        #expect(byName["文件夹"]?.kind == .directory)
        #expect(byName[".hidden"]?.isHidden == true)

        let details = try await service.details(ServicePath("docs/100% ?#;.txt"))
        #expect(details.size == 1)
        let folder = try await service.details(ServicePath("docs/文件夹"))
        #expect(folder.kind == .directory)
        let root = try await service.details(.root)
        #expect(root.kind == .directory)
        await #expect(throws: WebDAVError.notFound(path: "missing")) {
            _ = try await service.details(ServicePath("missing"))
        }
        await service.disconnect()
    }

    @Test
    func `A wrong password is the account refused, and a closed session sends nothing`() async throws {
        let loopback = try await LoopbackServer()
        let service = loopback.service(password: "wrong")
        await #expect(throws: WebDAVError.authenticationFailed) {
            _ = try await service.details(.root)
        }
        await service.disconnect()
        await #expect(throws: WebDAVError.disconnected) {
            _ = try await service.details(.root)
        }
    }

    @Test
    func `A file is read into the descriptor as it arrives`() async throws {
        let loopback = try await LoopbackServer()
        let payload = pattern(3 * 1024 * 1024 + 17)
        try payload.write(to: URL(fileURLWithPath: loopback.scratch.path("big.bin")))
        let service = loopback.service()
        let target = "/private/tmp/fila-webdav-download-" + UUID().uuidString
        let descriptor = open(target, O_CREAT | O_EXCL | O_RDWR, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor); unlink(target) }
        let reports = Reports()
        try await service.copyContents(of: ServicePath("big.bin"), to: descriptor) { reports.append($0) }
        #expect(FileManager.default.contents(atPath: target) == payload)
        #expect(reports.all.last == TransferProgress(completed: Int64(payload.count), expected: Int64(payload.count)))
        await #expect(throws: WebDAVError.notFound(path: "nope")) {
            try await service.copyContents(of: ServicePath("nope"), to: descriptor) { _ in }
        }
        await service.disconnect()
    }

    @Test
    func `A file is uploaded to a private name, published exclusively, and replaced only when asked`() async throws {
        let loopback = try await LoopbackServer()
        loopback.scratch.directory("up")
        let service = loopback.service()
        let payload = pattern(2 * 1024 * 1024 + 321)
        let (descriptor, local) = try localFile(payload)
        defer { close(descriptor); try? FileManager.default.removeItem(at: local) }
        let target = try ServicePath("up/uploaded.bin")
        let reports = Reports()
        try await service.writeFile(from: descriptor, size: Int64(payload.count), to: target, policy: .failIfExists) {
            reports.append($0)
        }
        #expect(loopback.data("up/uploaded.bin") == payload)
        #expect(reports.all.last?.completed == Int64(payload.count))
        #expect(loopback.names("up") == ["uploaded.bin"], "no temporary is left")

        let (other, otherURL) = try localFile(Data("other".utf8))
        defer { close(other); try? FileManager.default.removeItem(at: otherURL) }
        await #expect(throws: WriteFailure.alreadyExists(target)) {
            try await service.writeFile(from: other, size: 5, to: target, policy: .failIfExists) { _ in }
        }
        #expect(loopback.data("up/uploaded.bin") == payload)
        #expect(loopback.names("up") == ["uploaded.bin"])

        try await service.writeFile(from: other, size: 5, to: target, policy: .replace) { _ in }
        #expect(loopback.data("up/uploaded.bin") == Data("other".utf8))
        #expect(loopback.names("up") == ["uploaded.bin"])

        // A folder at the name is never taken by a replacement.
        loopback.scratch.directory("up/folder")
        loopback.scratch.file("up/folder/keep.txt", contents: "keep")
        await #expect(throws: WriteFailure.notEmpty(try ServicePath("up/folder"))) {
            try await service.writeFile(from: other, size: 5, to: ServicePath("up/folder"), policy: .replace) { _ in }
        }
        #expect(loopback.scratch.contents("up/folder/keep.txt") == "keep")
        #expect(loopback.names("up") == ["uploaded.bin", "folder"])

        let (empty, emptyURL) = try localFile(Data())
        defer { close(empty); try? FileManager.default.removeItem(at: emptyURL) }
        try await service.writeFile(from: empty, size: 0, to: ServicePath("up/empty"), policy: .failIfExists) { _ in }
        #expect(loopback.data("up/empty") == Data())

        await #expect(throws: WriteFailure.notFound(try ServicePath("missing/x"))) {
            try await service.writeFile(from: empty, size: 0, to: ServicePath("missing/x"), policy: .failIfExists) { _ in }
        }
        #expect(!loopback.names().contains("missing"))
        await service.disconnect()
    }

    @Test
    func `A file shorter than its size is never published`() async throws {
        let loopback = try await LoopbackServer()
        let service = loopback.service()
        let (descriptor, local) = try localFile(Data("short".utf8))
        defer { close(descriptor); try? FileManager.default.removeItem(at: local) }
        await #expect(throws: (any Error).self) {
            try await service.writeFile(from: descriptor, size: 1000, to: ServicePath("short.txt"), policy: .failIfExists) { _ in }
        }
        // The server discards its own staging once its read times out.
        for _ in 0 ..< 100 where !loopback.names().isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(loopback.names().isEmpty, "\(loopback.names())")
        await service.disconnect()
    }

    @Test
    func `A cancelled upload leaves neither the name nor a temporary`() async throws {
        let loopback = try await LoopbackServer()
        let service = loopback.service()
        let size = 48 * 1024 * 1024
        let (descriptor, local) = try localFile(Data(count: size))
        defer { close(descriptor); try? FileManager.default.removeItem(at: local) }
        let reports = Reports()
        let upload = Task {
            try await service.writeFile(from: descriptor, size: Int64(size), to: ServicePath("big"), policy: .failIfExists) {
                reports.append($0)
            }
        }
        while (reports.all.last?.completed ?? 0) < 1024 * 1024 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        upload.cancel()
        if case .success = await upload.result {
            Issue.record("a cancelled upload completed")
        }
        for _ in 0 ..< 100 where !loopback.names().isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(loopback.names().isEmpty, "\(loopback.names())")
        await service.disconnect()
    }

    @Test
    func `Folders are made, a full one is refused, and removal never recurses`() async throws {
        let loopback = try await LoopbackServer()
        let service = loopback.service()
        let made = try ServicePath("made")
        try await service.createDirectory(made)
        #expect(loopback.names() == ["made"])
        await #expect(throws: WriteFailure.alreadyExists(made)) {
            try await service.createDirectory(made)
        }
        await #expect(throws: WriteFailure.notFound(try ServicePath("no/such"))) {
            try await service.createDirectory(ServicePath("no/such"))
        }
        loopback.scratch.file("made/inside.txt", contents: "x")
        await #expect(throws: WriteFailure.notEmpty(made)) {
            try await service.removeEmptyDirectory(made)
        }
        #expect(loopback.scratch.exists("made/inside.txt"), "nothing inside was touched")
        await #expect(throws: WebDAVError.wrongKind(path: "made")) {
            try await service.removeFile(made)
        }
        #expect(loopback.scratch.exists("made/inside.txt"))
        await #expect(throws: WebDAVError.wrongKind(path: "made/inside.txt")) {
            try await service.removeEmptyDirectory(ServicePath("made/inside.txt"))
        }
        try await service.removeFile(ServicePath("made/inside.txt"))
        try await service.removeEmptyDirectory(made)
        #expect(loopback.names().isEmpty)
        await #expect(throws: WriteFailure.notFound(made)) {
            try await service.removeEmptyDirectory(made)
        }
        await #expect(throws: WriteFailure.notFound(made)) {
            try await service.removeFile(made)
        }
        await service.disconnect()
    }

    @Test
    func `A rename is exclusive unless asked to replace, and never replaces a folder`() async throws {
        let loopback = try await LoopbackServer()
        loopback.scratch.file("a.txt", contents: "a")
        loopback.scratch.file("b.txt", contents: "b")
        loopback.scratch.directory("dir")
        loopback.scratch.file("dir/keep", contents: "k")
        let service = loopback.service()
        let a = try ServicePath("a.txt")
        let b = try ServicePath("b.txt")
        await #expect(throws: WriteFailure.alreadyExists(b)) {
            try await service.move(a, to: b, policy: .failIfExists)
        }
        #expect(loopback.scratch.contents("b.txt") == "b")
        await #expect(throws: WriteFailure.notEmpty(try ServicePath("dir"))) {
            try await service.move(a, to: ServicePath("dir"), policy: .replace)
        }
        #expect(loopback.scratch.contents("dir/keep") == "k")
        try await service.move(a, to: b, policy: .replace)
        #expect(loopback.scratch.contents("b.txt") == "a")
        try await service.move(ServicePath("dir"), to: ServicePath("moved dir"), policy: .failIfExists)
        #expect(loopback.scratch.contents("moved dir/keep") == "k")
        #expect(loopback.names() == ["b.txt", "moved dir"])
        await #expect(throws: WriteFailure.notFound(a)) {
            try await service.move(a, to: ServicePath("c.txt"), policy: .failIfExists)
        }
        await service.disconnect()
    }

    @Test
    @MainActor
    func `A tree moves from a local root to the server and back, complete at each end`() async throws {
        let loopback = try await LoopbackServer()
        let local = Scratch()
        let staging = Scratch()
        let big = pattern(1024 * 1024 + 77)
        local.directory("tree")
        local.directory("tree/sub")
        local.directory("tree/empty")
        local.file("tree/α β.txt", contents: "alpha")
        try big.write(to: URL(fileURLWithPath: local.path("tree/sub/big.bin")))
        let localService = LocalFileServiceAdapter(access: LocalFileService(), rootPath: local.root, observation: DirectoryObservation())
        let remote = loopback.service()
        loopback.scratch.directory("dest")

        let up = try TransferRequest(
            source: TransferSource(backend: BackendID("local"), service: localService, paths: [ServicePath("tree")]),
            destination: TransferDestination(backend: BackendID("webdav"), service: remote, directory: ServicePath("dest")),
            mode: .move, policy: .failIfExists,
        )
        let upResult = await FileTransfer.run(up, staging: URL(fileURLWithPath: staging.root)) { _ in }
        #expect(upResult.succeeded, "\(String(describing: upResult.failure))")
        #expect(loopback.scratch.contents("dest/tree/α β.txt") == "alpha")
        #expect(loopback.data("dest/tree/sub/big.bin") == big)
        #expect(loopback.names("dest/tree") == ["α β.txt", "sub", "empty"])
        #expect(!local.exists("tree"), "the move removed the local tree")

        let down = try TransferRequest(
            source: TransferSource(backend: BackendID("webdav"), service: remote, paths: [ServicePath("dest/tree")]),
            destination: TransferDestination(backend: BackendID("local"), service: localService, directory: .root),
            mode: .move, policy: .failIfExists,
        )
        let downResult = await FileTransfer.run(down, staging: URL(fileURLWithPath: staging.root)) { _ in }
        #expect(downResult.succeeded, "\(String(describing: downResult.failure))")
        #expect(local.contents("tree/α β.txt") == "alpha")
        #expect(FileManager.default.contents(atPath: local.path("tree/sub/big.bin")) == big)
        #expect(loopback.names("dest").isEmpty, "the move removed the server's tree")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: staging.root)) == [])
        await remote.disconnect()
    }
}
