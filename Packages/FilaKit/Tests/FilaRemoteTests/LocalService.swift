import CRemoveFile
import Darwin
import FilaFileOps
import FilaProtocol
import FilaRemote
import Foundation

/// `RemoteFileService` over the real filesystem, through the same
/// `FileOperations` the daemon dispatches to.
///
/// Not a mock. It is the daemon's own file layer with the XPC hop taken out, so
/// a test here exercises `copyfile`, `renamex_np`, `removefile` and `FilaGuard`
/// exactly as the device does — which is the entire reason the file layer lives
/// in a package instead of inside the daemon target.
final class LocalService: RemoteFileService, @unchecked Sendable {
    let operations: FileOperations
    private let jobDelayNanoseconds: UInt64

    init(bootstrapRoot: String = "", jobDelayNanoseconds: UInt64 = 0) {
        operations = FileOperations(bootstrapRoot: bootstrapRoot)
        self.jobDelayNanoseconds = jobDelayNanoseconds
    }

    func list(_ directory: String) async throws -> [FileNode] {
        // Its own registry per call rather than one shared and locked: the
        // daemon holds listings open between pages because a client asks for
        // them one at a time, and nothing here does.
        let listings = ListingRegistry()
        defer { listings.closeAll() }
        var entries: [FileNode] = []
        var cursor: UInt64 = 0
        repeat {
            let page = try listings.page(directory: directory, cursor: cursor)
            entries.append(contentsOf: page.entries)
            cursor = page.cursor
        } while cursor != 0
        return entries
    }

    func details(of path: String) async throws -> FileDetails {
        try operations.details(of: path)
    }

    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try operations.open(path, flags: flags, mode: mode)
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try operations.create(template, at: path)
    }

    func rename(_ source: String, to destination: String, exclusive: Bool) async throws {
        try operations.rename(source, to: destination, exclusive: exclusive)
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try operations.replaceItem(at: target, withTemporary: temporary)
    }

    func run(_ job: JobRequest) async throws {
        if jobDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: jobDelayNanoseconds) }
        let operations = operations
        // `FileJob.run` blocks its thread from start to finish — that is how
        // `copyfile`'s state callbacks work — so it goes somewhere it is
        // allowed to.
        let failure = await Task.detached { FileJob(request: job, operations: operations).run(report: { _ in }) }.value
        guard failure.code == .success else { throw failure }
    }
}

/// A real directory on a real filesystem, gone when the test is.
final class Scratch {
    let root: String

    init() {
        let name = "fila-remote-tests-\(getpid())-\(UInt32.random(in: 0 ..< .max))"
        let created = "/private/tmp/" + name
        precondition(mkdir(created, 0o755) == 0, "scratch: \(String(cString: strerror(errno)))")
        root = created
    }

    deinit {
        removefile(root, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
    }

    func path(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    @discardableResult
    func directory(_ relative: String) -> String {
        let path = self.path(relative)
        precondition(mkdir(path, 0o755) == 0 || errno == EEXIST, "mkdir \(path)")
        return path
    }

    @discardableResult
    func file(_ relative: String, contents: String = "fila") -> String {
        let path = self.path(relative)
        let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        precondition(descriptor >= 0, "open \(path)")
        contents.withCString { _ = write(descriptor, $0, strlen($0)) }
        close(descriptor)
        return path
    }

    func contents(_ relative: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path(relative)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        var found = stat()
        return lstat(path(relative), &found) == 0
    }
}
