import Darwin
@testable import FilaClient
@testable import FilaProtocol
import Foundation
import Testing

/// The app-side listing over a directory descriptor, against a real
/// directory: what it reads must be what `lstat` says, entry for entry.
@Suite("Directory bulk reader")
struct DirectoryBulkReaderTests {
    let scratch = LocalScratch()

    /// Opened the way the daemon opens a directory for the app: read-only,
    /// a directory or nothing, and `O_NONBLOCK` as every read-only open the
    /// daemon makes carries.
    private func open(_ path: String) throws -> DirectoryDescriptor {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NONBLOCK)
        try #require(descriptor >= 0, "open \(path): \(String(cString: strerror(errno)))")
        return DirectoryDescriptor(descriptor: descriptor)
    }

    private func readAll(_ path: String, resolveLink: (@Sendable (String) async -> FileKind?)? = nil) async throws -> [[FileNode]] {
        var batches: [[FileNode]] = []
        for try await batch in DirectoryBulkReader.entries(in: try open(path), path: path, resolveLink: resolveLink) {
            batches.append(batch)
        }
        return batches
    }

    /// Every field `lstat` reports that the browser shows, for one entry.
    private func expectMatchesStat(_ node: FileNode, at path: String) {
        var expected = stat()
        #expect(lstat(path, &expected) == 0, "\(node.name)")
        #expect(node.kind == FileKind(modeBits: expected.st_mode), "\(node.name)")
        #expect(node.mode == expected.st_mode, "\(node.name)")
        #expect(node.ownerID == expected.st_uid, "\(node.name)")
        #expect(node.groupID == expected.st_gid, "\(node.name)")
        #expect(node.inode == expected.st_ino, "\(node.name)")
        #expect(node.systemFlags == expected.st_flags, "\(node.name)")
        #expect(node.size == Int64(expected.st_size), "\(node.name)")
        #expect(node.allocatedSize == Int64(expected.st_blocks) * 512, "\(node.name)")
        #expect(abs(node.modified - seconds(expected.st_mtimespec)) < 0.001, "\(node.name)")
        #expect(abs(node.accessed - seconds(expected.st_atimespec)) < 0.001, "\(node.name)")
        #expect(abs(node.created - seconds(expected.st_birthtimespec)) < 0.001, "\(node.name)")
        // A directory's link count is the one place the two disagree:
        // `stat` counts `.` and `..` into a folder's, `getattrlist` does not.
        if node.kind != .directory {
            #expect(node.linkCount == UInt64(expected.st_nlink), "\(node.name)")
        }
    }

    private func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @Test("Every entry reads as lstat describes it, whatever its kind")
    func entriesMatchStat() async throws {
        let root = scratch.directory("mixed")
        let file = scratch.file("mixed/notes.txt", contents: String(repeating: "x", count: 1234))
        scratch.directory("mixed/folder")
        scratch.file("mixed/.dotfile")
        symlink("notes.txt", scratch.path("mixed/to-notes"))
        symlink("folder", scratch.path("mixed/to-folder"))
        symlink("nowhere", scratch.path("mixed/dangling"))
        mkfifo(scratch.path("mixed/pipe"), 0o600)
        let flagged = scratch.file("mixed/flagged")
        chflags(flagged, UInt32(UF_HIDDEN))
        chmod(file, 0o640)

        let nodes = try await readAll(root).flatMap { $0 }
        let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["notes.txt", "folder", ".dotfile", "to-notes", "to-folder", "dangling", "pipe", "flagged"])
        for node in nodes {
            expectMatchesStat(node, at: scratch.path("mixed/\(node.name)"))
        }
        #expect(byName["notes.txt"]?.size == 1234)
        #expect(byName["flagged"]?.isHidden == true)
        #expect(byName[".dotfile"]?.isHidden == true)
        #expect(byName["notes.txt"]?.isHidden == false)
        #expect(byName["to-notes"]?.link == SymbolicLink(target: "notes.txt", resolvedKind: .regular))
        #expect(byName["to-folder"]?.link == SymbolicLink(target: "folder", resolvedKind: .directory))
        #expect(byName["to-folder"]?.isNavigable == true)
        #expect(byName["dangling"]?.link == SymbolicLink(target: "nowhere", resolvedKind: nil))
        #expect(byName["dangling"]?.link?.isBroken == true)
        #expect(byName["pipe"]?.kind == .fifo)
    }

    /// devfs does not support a creation time. With `FSOPT_PACK_INVAL_ATTRS`
    /// the field is still in the buffer, and a parser that read the returned
    /// set as presence would slide every later field: device nodes with
    /// four-gigabyte sizes and nonsense owners.
    @Test("A volume that lacks an attribute leaves every other field where it is")
    func unsupportedAttributeKeepsLayout() async throws {
        let nodes = try await readAll("/dev").flatMap { $0 }
        let null = try #require(nodes.first { $0.name == "null" })
        var expected = stat()
        #expect(lstat("/dev/null", &expected) == 0)
        #expect(null.kind == .characterDevice)
        #expect(null.mode == expected.st_mode)
        #expect(null.ownerID == expected.st_uid)
        #expect(null.groupID == expected.st_gid)
        #expect(null.inode == expected.st_ino)
        #expect(null.size == Int64(expected.st_size))
        // Not its modified time: every write to /dev/null moves it, and
        // the rest of the suite writes there while this runs.
        #expect(null.created == 0)
    }

    @Test("A name that is not UTF-8 still appears, repaired, as the daemon lists it")
    func invalidNameIsListed() async throws {
        let root = scratch.directory("bytes")
        let raw: [UInt8] = Array(root.utf8) + [0x2F, 0x62, 0xFF, 0x61, 0x64, 0x00] // "/b\xFFad"
        let descriptor = raw.withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { Darwin.open($0.baseAddress!, O_CREAT | O_WRONLY, 0o644) }
        }
        // APFS refuses such a name outright (EILSEQ); the case is for the
        // volumes that do not, and there is nothing to test where it cannot exist.
        guard descriptor >= 0 else { return }
        close(descriptor)
        let names = try await readAll(root).flatMap { $0 }.map(\.name)
        #expect(names.count == 1)
        #expect(names.first?.hasPrefix("b") == true)
        #expect(names.first?.hasSuffix("ad") == true)
        #expect(names.first?.contains("\u{FFFD}") == true)
    }

    @Test("A long directory streams in batches with no entry twice")
    func streamsInBatches() async throws {
        let root = scratch.directory("many")
        for index in 0 ..< 1500 {
            scratch.file("many/entry-\(index)", contents: "")
        }
        let batches = try await readAll(root)
        #expect(batches.count > 1)
        let names = batches.flatMap { $0 }.map(\.name)
        #expect(names.count == 1500)
        #expect(Set(names).count == 1500)
    }

    /// The consumer's cap is the reader's: past it the reader stops rather
    /// than filling the stream's buffer with rows nobody will show. The
    /// batch that crosses the cap is delivered whole, so the consumer sees
    /// more than its cap and knows the listing was cut; a directory of
    /// exactly the cap is not cut.
    @Test("The reader stops once it has yielded past the limit")
    func stopsPastLimit() async throws {
        let root = scratch.directory("capped")
        for index in 0 ..< 1500 {
            scratch.file("capped/entry-\(index)", contents: "")
        }
        var yielded = 0
        var batches = 0
        for try await batch in DirectoryBulkReader.entries(in: try open(root), path: root, limit: 100) {
            yielded += batch.count
            batches += 1
        }
        #expect(batches == 1)
        #expect(yielded > 100)
        #expect(yielded < 1500)

        let exact = try await DirectoryBulkReader.entries(in: try open(root), path: root, limit: 1500)
            .reduce(into: 0) { $0 += $1.count }
        #expect(exact == 1500)
    }

    /// `getattrlistbulk` describes the directory a mount covers, `stat` the
    /// mounted volume's root; the browser shows the latter, as the daemon
    /// did. The Data volume is mounted on every Mac this runs on.
    @Test("A mount point reads as the mounted volume, as the daemon listed it")
    func mountPointIsTheMountedVolume() async throws {
        let parent = "/System/Volumes"
        let nodes = try await readAll(parent).flatMap { $0 }
        let data = try #require(nodes.first { $0.name == "Data" })
        var mounted = stat()
        #expect(stat("\(parent)/Data", &mounted) == 0)
        #expect(data.kind == .directory)
        #expect(data.inode == mounted.st_ino)
        #expect(data.ownerID == mounted.st_uid)
        #expect(abs(data.created - seconds(mounted.st_birthtimespec)) < 0.001)
        #expect(abs(data.modified - seconds(mounted.st_mtimespec)) < 0.001)
        #expect(data.linkCount == UInt64(mounted.st_nlink))
    }

    // Root can enter anything: the refusals below cannot happen to it.

    @Test("A link into a folder this process cannot enter is resolved through the backend", .enabled(if: geteuid() != 0))
    func refusedLinkIsResolvedByCallback() async throws {
        let root = scratch.directory("links")
        scratch.directory("links/locked")
        scratch.file("links/locked/secret", contents: "s")
        symlink("locked/secret", scratch.path("links/into-locked"))
        symlink("nowhere", scratch.path("links/dangling"))
        chmod(scratch.path("links/locked"), 0)
        defer { chmod(scratch.path("links/locked"), 0o755) }

        let unresolved = try await readAll(root).flatMap { $0 }
        #expect(unresolved.first { $0.name == "into-locked" }?.link == SymbolicLink(target: "locked/secret", resolvedKind: nil))

        let asked = LockedBox<[String]>([])
        let resolved = try await readAll(root) { name in
            asked.mutate { $0.append(name) }
            return .regular
        }.flatMap { $0 }
        #expect(resolved.first { $0.name == "into-locked" }?.link?.resolvedKind == .regular)
        // The refused link, and only that: a dangling one is not asked about.
        #expect(asked.value == ["into-locked"])
    }

    @Test("Letting go of the stream closes the descriptor")
    func abandonmentClosesDescriptor() async throws {
        let root = scratch.directory("abandoned")
        for index in 0 ..< 3000 {
            scratch.file("abandoned/entry-\(index)", contents: "")
        }
        let directory = try open(root)
        do {
            var iterator = DirectoryBulkReader.entries(in: directory, path: root).makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.isEmpty == false)
        }
        // The producer closes on its next turn after the consumer is gone.
        for _ in 0 ..< 100 where directory.fileDescriptor >= 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The owner's sentinel is what can be asserted: the number itself
        // is reused by whatever opens next.
        #expect(directory.fileDescriptor == -1)
    }

    @Test("A directory the process may not search fails before any entry, with the errno", .enabled(if: geteuid() != 0))
    func unsearchableDirectoryFails() async throws {
        let root = scratch.directory("sealed")
        scratch.file("sealed/inside", contents: "")
        chmod(root, 0o400)
        defer { chmod(root, 0o755) }
        let directory = try open(root)
        var delivered = 0
        var failure: FilaFailure?
        do {
            for try await batch in DirectoryBulkReader.entries(in: directory, path: root) {
                delivered += batch.count
            }
        } catch let refused as FilaFailure {
            failure = refused
        }
        // The contract the browser's fallback is written against.
        #expect(delivered == 0)
        #expect(failure?.systemError == EACCES)
        #expect(failure?.code == .notPermitted)
        #expect(directory.fileDescriptor == -1)
    }
}

/// A box for a value tests mutate from a `@Sendable` closure.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}
