import FilaBackendKit
@testable import FilaSMB
import Foundation
import Testing

/// Against a real SMB2 server, named by the environment:
///
///     FILA_SMB_SERVER=host:port FILA_SMB_SHARE=name \
///     FILA_SMB_USER=account FILA_SMB_PASSWORD=secret \
///     FILA_SMB_FIXTURES=/path/the/share/serves \
///     swift test --package-path Packages/FilaKit --filter SMBLiveServer
///
/// `FILA_SMB_FIXTURES` is the directory the share exports, so the tests can
/// lay down what they list and read. Without `FILA_SMB_SERVER` every test
/// here is skipped: the harness never needs a network.
@Suite("SMB live server", .serialized)
struct SMBLiveServerTests {
    struct Server {
        let host: String
        let port: Int
        let share: String
        let user: String?
        let password: String?
        let fixtures: URL

        static var configured: Server? {
            let environment = ProcessInfo.processInfo.environment
            guard let server = environment["FILA_SMB_SERVER"], let fixtures = environment["FILA_SMB_FIXTURES"] else {
                return nil
            }
            let pieces = server.split(separator: ":")
            let host = String(pieces[0])
            let port = pieces.count > 1 ? Int(pieces[1]) ?? SMBProfile.defaultPort : SMBProfile.defaultPort
            return Server(
                host: host,
                port: port,
                share: environment["FILA_SMB_SHARE"] ?? "SHARE",
                user: environment["FILA_SMB_USER"],
                password: environment["FILA_SMB_PASSWORD"],
                fixtures: URL(fileURLWithPath: fixtures)
            )
        }

        func profile(share: String? = nil, user: String?? = nil) -> SMBProfile {
            SMBProfile(name: "Live", host: host, port: port, share: share ?? self.share, username: user ?? self.user)
        }

        func service(password: String?? = nil, requestTimeout: TimeInterval = 30) -> SMBFileService {
            SMBFileService(
                profile: profile(), password: password ?? self.password, pollInterval: 0.2,
                connectTimeout: 10, requestTimeout: requestTimeout
            )
        }
    }

    /// A fresh directory under the fixtures, removed afterwards.
    private func withFixture(_ server: Server, _ body: (String, URL) async throws -> Void) async throws {
        let name = "live-" + UUID().uuidString.prefix(8)
        let directory = server.fixtures.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(name, directory)
    }

    private func stagingDescriptor() throws -> (Int32, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smb-staging-" + UUID().uuidString)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        try #require(descriptor >= 0)
        return (descriptor, url)
    }

    @Test("Listing pulls a large directory page by page and keeps every name")
    func pagedListing() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            for index in 0 ..< 2500 {
                FileManager.default.createFile(atPath: directory.appendingPathComponent("entry-\(index).txt").path, contents: nil)
            }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("日本語 папка"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("émoji 🎉.bin").path, contents: Data([1, 2, 3]))
            let service = server.service()
            var batches = 0
            var names: Set<String> = []
            var directories: [String] = []
            for try await batch in try await service.list(try ServicePath(name)) {
                batches += 1
                #expect(!batch.isEmpty)
                for entry in batch {
                    names.insert(entry.name)
                    if entry.kind == .directory { directories.append(entry.name) }
                    if entry.name == "émoji 🎉.bin" { #expect(entry.size == 3) }
                }
            }
            #expect(batches > 1, "2500 entries do not fit one response")
            #expect(names.count == 2502)
            #expect(!names.contains("."), "dot entries are the server's, not the folder's")
            #expect(names.contains("日本語 папка"))
            #expect(directories == ["日本語 папка"])
            await service.disconnect()
        }
    }

    @Test("Stopping a listing early closes its handle and the next listing still works")
    func abandonedListing() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            for index in 0 ..< 1200 {
                FileManager.default.createFile(atPath: directory.appendingPathComponent("e\(index)").path, contents: nil)
            }
            let service = server.service()
            let path = try ServicePath(name)
            let listing = try await service.list(path)
            var iterator = listing.makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.isEmpty == false)
            let task = Task {
                var count = 0
                for try await batch in try await service.list(path) { count += batch.count }
                return count
            }
            #expect(try await task.value == 1200)
            await service.disconnect()
        }
    }

    @Test("Details describe the root, a file, an empty file and a missing path honestly")
    func details() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            FileManager.default.createFile(atPath: directory.appendingPathComponent("five").path, contents: Data("hello".utf8))
            FileManager.default.createFile(atPath: directory.appendingPathComponent("empty").path, contents: Data())
            let service = server.service()
            let root = try await service.details(.root)
            #expect(root.kind == .directory)
            #expect(root.name == server.share)
            let five = try await service.details(try ServicePath("\(name)/five"))
            #expect(five.kind == .file)
            #expect(five.size == 5)
            #expect(five.modified != nil)
            let empty = try await service.details(try ServicePath("\(name)/empty"))
            #expect(empty.size == 0)
            do {
                _ = try await service.details(try ServicePath("\(name)/missing"))
                Issue.record("a missing path was described")
            } catch let error as SMBError {
                #expect(error == .notFound(path: "\(name)/missing"))
            }
            await service.disconnect()
        }
    }

    @Test("A large file is copied in bounded chunks with monotonic progress; an empty one reports zero")
    func copyContents() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let size = 48 * 1024 * 1024
            var content = Data(count: size)
            content.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                for index in stride(from: 0, to: size, by: 4096) { buffer[index] = UInt8(truncatingIfNeeded: index / 4096) }
            }
            try content.write(to: directory.appendingPathComponent("big"))
            FileManager.default.createFile(atPath: directory.appendingPathComponent("empty").path, contents: Data())
            let service = server.service()
            let (descriptor, staging) = try stagingDescriptor()
            defer { close(descriptor); try? FileManager.default.removeItem(at: staging) }
            let progress = ProgressLog()
            try await service.copyContents(of: try ServicePath("\(name)/big"), to: descriptor) { progress.append($0) }
            let reports = progress.reports
            #expect(reports.first?.completed == 0)
            #expect(reports.last?.completed == Int64(size))
            #expect(reports.allSatisfy { $0.expected == Int64(size) })
            #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.completed <= $1.completed })
            #expect(reports.count > 10, "a 48 MiB file is many one-megabyte chunks")
            #expect(try Data(contentsOf: staging) == content)

            let (emptyDescriptor, emptyStaging) = try stagingDescriptor()
            defer { close(emptyDescriptor); try? FileManager.default.removeItem(at: emptyStaging) }
            let emptyProgress = ProgressLog()
            try await service.copyContents(of: try ServicePath("\(name)/empty"), to: emptyDescriptor) { emptyProgress.append($0) }
            #expect(emptyProgress.reports.map(\.completed) == [0])
            #expect(emptyProgress.reports.first?.expected == 0)
            await service.disconnect()
        }
    }

    @Test("Cancelling a transfer stops it, leaves the descriptor alone afterwards, and the next request reconnects")
    func cancelledTransfer() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            try Data(count: 64 * 1024 * 1024).write(to: directory.appendingPathComponent("big"))
            let service = server.service()
            let (descriptor, staging) = try stagingDescriptor()
            defer { close(descriptor); try? FileManager.default.removeItem(at: staging) }
            let progress = ProgressLog()
            let transfer = Task {
                try await service.copyContents(of: try ServicePath("\(name)/big"), to: descriptor) { report in
                    progress.append(report)
                }
            }
            while progress.reports.count < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
            transfer.cancel()
            let outcome = await transfer.result
            switch outcome {
            case .success: Issue.record("a cancelled transfer completed")
            case let .failure(error):
                #expect(error is CancellationError || (error as? SMBError) == .disconnected, "got \(error)")
            }
            let sizeAtReturn = try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int
            try await Task.sleep(nanoseconds: 200_000_000)
            let sizeLater = try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int
            #expect(sizeAtReturn == sizeLater, "nothing touches the descriptor after return")
            #expect((sizeLater ?? 0) < 64 * 1024 * 1024)
            // A fresh session behind the same service.
            let entry = try await service.details(try ServicePath("\(name)/big"))
            #expect(entry.size == Int64(64 * 1024 * 1024))
            await service.disconnect()
        }
    }

    @Test("A connection past its budget fails as a timeout, within that budget")
    func connectTimeout() async throws {
        guard Server.configured != nil else { return }
        // An address on a test network that nothing routes: the SYN goes
        // nowhere and only the budget brings the request back.
        let profile = SMBProfile(name: "Nowhere", host: "192.0.2.1", share: "s")
        let service = SMBFileService(profile: profile, password: nil, connectTimeout: 1, requestTimeout: 1)
        let started = Date()
        do {
            _ = try await service.details(.root)
            Issue.record("an unroutable host answered")
        } catch let error as SMBError {
            #expect(error == .timedOut(operation: "connect"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
        await service.disconnect()
    }

    @Test("A request past its budget retires the session and the next request reconnects")
    func requestTimeout() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            try Data(count: 32 * 1024 * 1024).write(to: directory.appendingPathComponent("big"))
            let service = server.service()
            _ = try await service.details(try ServicePath("\(name)/big"))
            // A budget no request meets once the session is up: the first
            // read after this must time out, retire the session, and the
            // details call after it must get a fresh one.
            await service.connection.setRequestTimeout(0)
            let (descriptor, staging) = try stagingDescriptor()
            defer { close(descriptor); try? FileManager.default.removeItem(at: staging) }
            var sawTimeout = false
            do {
                try await service.copyContents(of: try ServicePath("\(name)/big"), to: descriptor) { _ in }
            } catch let error as SMBError {
                if case .timedOut = error { sawTimeout = true }
                if error == .disconnected { sawTimeout = true }
            }
            #expect(sawTimeout)
            await service.connection.setRequestTimeout(30)
            let entry = try await service.details(try ServicePath("\(name)/big"))
            #expect(entry.size == Int64(32 * 1024 * 1024))
            await service.disconnect()
        }
    }

    @Test("Wrong password and unknown share are named, and the connection fails within its budget")
    func refusals() async throws {
        guard let server = Server.configured, server.user != nil else { return }
        let wrongPassword = server.service(password: .some("not-the-password"))
        do {
            _ = try await wrongPassword.details(.root)
            Issue.record("a wrong password was accepted")
        } catch let error as SMBError {
            #expect(error == .authenticationFailed)
        }
        let unknownShare = SMBFileService(profile: server.profile(share: "no-such-share"), password: server.password, connectTimeout: 10)
        do {
            _ = try await unknownShare.details(.root)
            Issue.record("an unknown share was connected")
        } catch let error as SMBError {
            #expect(error == .shareNotFound("no-such-share"))
        }
    }

    @Test("A change stream hints at once, then when the directory changes, and ends when the session is lost")
    func changes() async throws {
        guard let server = Server.configured else { return }
        try await withFixture(server) { name, directory in
            let service = server.service()
            let path = try ServicePath(name)
            let hints = HintLog()
            let consumer = Task {
                do {
                    for try await _ in try await service.changes(in: path) { hints.hinted() }
                    return nil as SMBError?
                } catch {
                    return error as? SMBError
                }
            }
            try await hints.wait(for: 1, seconds: 5)
            await #expect(service.observation.subscriberCount == 1)
            // A second subscriber, to another directory, keeps its own hints.
            let otherHints = HintLog()
            let other = Task {
                for try await _ in try await service.changes(in: .root) { otherHints.hinted() }
            }
            try await otherHints.wait(for: 1, seconds: 5)
            try await Task.sleep(nanoseconds: 300_000_000)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("new").path, contents: Data("x".utf8))
            try await hints.wait(for: 2, seconds: 5)
            #expect(otherHints.count == 1, "the root was not touched")
            await service.disconnect()
            let ending = await consumer.value
            #expect(ending == .disconnected)
            other.cancel()
        }
    }
}

final class HintLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hints = 0

    func hinted() {
        lock.lock(); defer { lock.unlock() }
        hints += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return hints
    }

    struct Timeout: Error {}

    /// Returns once `count` hints arrived, or throws after `seconds`.
    func wait(for expected: Int, seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while count < expected {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TransferProgress] = []

    func append(_ report: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        log.append(report)
    }

    var reports: [TransferProgress] {
        lock.lock(); defer { lock.unlock() }
        return log
    }
}
