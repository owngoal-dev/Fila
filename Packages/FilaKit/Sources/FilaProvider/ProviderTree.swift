import CryptoKit
import Darwin
import FilaFileOps
import FilaProtocol
import Foundation

/// One folder, as Files sees it through the replicated File Provider.
///
/// The system keeps the on-disk replica, every download and every conflict;
/// this answers "what is in the folder", hands out content, and applies the
/// mutations Files asks for. It runs under the extension's own permissions and
/// never talks to `filad`.
///
/// **An item is its inode.** APFS never reuses an inode number, so a rename or
/// a move keeps the item and its replica and only the metadata version moves.
/// The index on disk is the last state reported to the system, which is what a
/// change enumeration diffs against; losing it costs one re-enumeration and
/// nothing else, because the identifiers come from the filesystem.
///
/// Symlinks, special nodes and multiply linked files are left out: a link would
/// hand Files whatever it points at, and a second name for an inode is a
/// second place its content changes from.
public final class ProviderTree {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        /// The parent's id; nil directly under the root.
        public var parent: String?
        /// Relative to the root.
        public var path: String
        public var isDirectory: Bool
        public var size: Int64
        public var created: Date
        public var modified: Date
        public var contentVersion: String
        public var metadataVersion: String

        public var name: String { (path as NSString).lastPathComponent }
    }

    public struct Changes {
        public let updated: [Entry]
        public let deleted: [Entry]
        public let anchor: Data
    }

    public enum Failure: Error, Equatable {
        case missing
        case collision
        case directoryNotEmpty
        case invalidName
        case unsupported
        case permission
        case noSpace
        case io(Int32)
    }

    public let root: URL
    private let index: URL
    private let operations: FileOperations
    /// The last state reported to the system, by id.
    private var entries: [String: Entry] = [:]
    /// Recent baselines, so an enumerator holding a slightly older anchor gets
    /// a diff rather than an expiry while another enumerator moved on.
    private var history: [(anchor: Data, entries: [String: Entry])] = []
    private var lastRescan = Date.distantPast

    private static let temporaryPrefix = ".fila-provider-"
    private static let historyLimit = 8

    public init(root: URL, index: URL) throws {
        let path = try FilaPath.resolve(root.path)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Self.failure(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsupported }
        self.root = URL(fileURLWithPath: path, isDirectory: true)
        self.index = index
        operations = FileOperations(bootstrapRoot: path, writableRoot: path)
        let indexDirectory = index.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A corrupt index is not a corrupt folder: the identifiers come from
        // the filesystem, so starting empty costs one re-enumeration.
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    // MARK: - Reading

    /// The item, re-read from disk. A stale index entry is corrected by one
    /// rescan; an item that is nowhere in the folder is `missing`.
    public func entry(_ id: String) throws -> Entry {
        if let known = entries[id], let fresh = refreshed(known) {
            if fresh != known { try commit(entries.merging([id: fresh]) { _, new in new }) }
            return fresh
        }
        // ponytail: a full rescan per miss, held to one every two seconds so a
        // burst of lookups after an external delete does not scan per item.
        guard Date().timeIntervalSince(lastRescan) > 2 else { throw Failure.missing }
        try rescan()
        guard let found = entries[id] else { throw Failure.missing }
        return found
    }

    /// The direct children of a folder, as they are now. `nil` is the root.
    public func children(of parent: String?) throws -> [Entry] {
        let base = try directory(parent)
        let listed = try list(base, parent: parent)
        var next = entries.filter { $0.value.parent != parent }
        for entry in listed { next[entry.id] = entry }
        try commit(next)
        return listed
    }

    /// Everything, after a full rescan. What the working set enumerates.
    public func all() throws -> [Entry] {
        try rescan()
        return entries.values.sorted { $0.path < $1.path }
    }

    /// The absolute path of any item, for watching it. The root for nil.
    public func path(of id: String?) throws -> String {
        guard let id else { return root.path }
        return try absolute(entry(id).path)
    }

    /// The absolute path of a regular file, for a read. Not a directory.
    public func contentsPath(of id: String) throws -> String {
        let entry = try entry(id)
        guard !entry.isDirectory else { throw Failure.unsupported }
        return try absolute(entry.path)
    }

    /// A clone of the file at `id`, for the system to take ownership of.
    public func exportContents(of id: String, to destination: URL) throws {
        let source = try contentsPath(of: id)
        do {
            let export = FileOperations(bootstrapRoot: "", writableRoot: destination.deletingLastPathComponent().path)
            try export.copyRegularFile(at: source, to: destination.path)
        } catch { throw Self.failure(error) }
    }

    // MARK: - Change tracking

    public var anchor: Data { Self.digest(entries) }

    /// What changed since `anchor`, or nil when that baseline is gone and the
    /// system has to enumerate again.
    public func changes(since anchor: Data) throws -> Changes? {
        let baseline: [String: Entry]
        if anchor == self.anchor {
            baseline = entries
        } else if let past = history.first(where: { $0.anchor == anchor }) {
            baseline = past.entries
        } else {
            return nil
        }
        try rescan()
        let updated = entries.values.filter { baseline[$0.id] != $0 }.sorted { $0.path < $1.path }
        let deleted = baseline.values.filter { entries[$0.id] == nil }
        return Changes(updated: updated, deleted: deleted, anchor: self.anchor)
    }

    // MARK: - Mutations

    public func createDirectory(name: String, parent: String?) throws -> Entry {
        let relative = try destination(name: name, parent: parent)
        do { try operations.create(.directory, at: absolute(relative)) }
        catch { throw Self.failure(error) }
        return try adopt(relative, parent: parent)
    }

    /// A new file with the bytes at `contents`, or empty. Exclusive: an
    /// existing name is a collision, never a replacement.
    public func createFile(name: String, parent: String?, contents: URL?) throws -> Entry {
        let relative = try destination(name: name, parent: parent)
        do {
            if let contents { try operations.copyRegularFile(at: contents.path, to: absolute(relative)) }
            else { try operations.create(.emptyFile, at: absolute(relative)) }
        } catch { throw Self.failure(error) }
        return try adopt(relative, parent: parent)
    }

    /// The child named `name` under `parent`, when the system says the item it
    /// is creating may already be there.
    public func existing(name: String, parent: String?) throws -> Entry? {
        try children(of: parent).first { $0.name == name }
    }

    /// New bytes for an existing file, atomically: a sibling temporary and a
    /// rename, with the old file's metadata carried across. The rename swaps
    /// the inode, so **the returned entry has a new id**; the caller reports it
    /// as the item the old one merged into, which is what the API provides for.
    public func replaceContents(of id: String, with contents: URL) throws -> Entry {
        let old = try entry(id)
        guard !old.isDirectory else { throw Failure.unsupported }
        let target = try absolute(old.path)
        let temporary = FilaPath.join(FilaPath.directory(of: target), Self.temporaryPrefix + UUID().uuidString)
        var ownsTemporary = false
        do {
            try operations.copyRegularFile(at: contents.path, to: temporary)
            ownsTemporary = true
            // Replacement inherits the destination's flags. Flags copied from
            // the incoming document must not prevent publishing the temporary.
            try operations.setAttributes(AttributeChange(systemFlags: 0), at: temporary)
            try operations.replaceItem(at: target, withTemporary: temporary)
        } catch {
            if ownsTemporary {
                guard unlink(temporary) == 0 || errno == ENOENT else { throw Self.failure(errno: errno) }
            }
            throw Self.failure(error)
        }
        var next = entries
        next[old.id] = nil
        try commit(next)
        return try adopt(old.path, parent: old.parent)
    }

    /// Rename, move, or both. Exclusive, so a name already in use is a
    /// collision rather than a silent replacement.
    public func move(_ id: String, name: String, parent: String?) throws -> Entry {
        let old = try entry(id)
        let relative = try destination(name: name, parent: parent, moving: old)
        if relative == old.path { return old }
        do { try operations.rename(absolute(old.path), to: absolute(relative), exclusive: true) }
        catch { throw Self.failure(error) }
        var next = entries
        for (key, entry) in entries where entry.path == old.path || entry.path.hasPrefix(old.path + "/") {
            var moved = entry
            moved.path = relative + entry.path.dropFirst(old.path.count)
            if key == id { moved.parent = parent }
            next[key] = moved
        }
        try commit(next)
        return try entry(id)
    }

    public func setModificationDate(_ id: String, _ date: Date) throws -> Entry {
        let entry = try entry(id)
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= Double(Int.min), seconds < Double(Int.max) else { throw Failure.unsupported }
        do { try operations.setAttributes(AttributeChange(modified: seconds), at: absolute(entry.path)) }
        catch { throw Self.failure(error) }
        return try self.entry(id)
    }

    /// Permanent. A folder goes only when empty unless `recursive`; the system
    /// asks for the recursive form when the user confirmed a whole folder.
    public func delete(_ id: String, recursive: Bool) throws {
        let entry = try entry(id)
        let path = try absolute(entry.path)
        if entry.isDirectory, !recursive {
            do { try operations.removeEmptyDirectory(at: path) }
            catch { throw Self.failure(error) }
        } else {
            let job = FileJob(request: JobRequest(kind: .delete, sources: [path]), operations: operations)
            let result = job.run(report: { _ in })
            guard result.code == .success else { throw Self.failure(result) }
        }
        try commit(entries.filter { $0.value.path != entry.path && !$0.value.path.hasPrefix(entry.path + "/") })
    }

    // MARK: - The folder on disk

    private func absolute(_ relative: String) throws -> String {
        // Cached paths describe descendants, never filesystem aliases. A
        // moved parent or an unreadable index must not widen this provider.
        guard !relative.hasPrefix("/"), !relative.utf8.contains(0),
              !relative.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw Failure.missing
        }
        let path = relative.isEmpty ? root.path : FilaPath.join(root.path, relative)
        do {
            guard try FilaPath.canonical(path) == path else { throw Failure.missing }
            return path
        } catch { throw Self.failure(error) }
    }

    /// The relative path of a folder to list into. Root for nil.
    private func directory(_ id: String?) throws -> String {
        guard let id else { return "" }
        let parent = try entry(id)
        guard parent.isDirectory else { throw Failure.missing }
        return parent.path
    }

    private func destination(name: String, parent: String?, moving: Entry? = nil) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              !name.hasPrefix(Self.temporaryPrefix), name.utf8.count <= 255 else { throw Failure.invalidName }
        let base = try directory(parent)
        if let moving, moving.isDirectory, base == moving.path || base.hasPrefix(moving.path + "/") {
            throw Failure.invalidName
        }
        let relative = base.isEmpty ? name : base + "/" + name
        if let moving, relative == moving.path { return relative }
        var info = stat()
        guard lstat(try absolute(relative), &info) != 0 else { throw Failure.collision }
        guard errno == ENOENT else { throw Self.failure(errno: errno) }
        return relative
    }

    /// Record a node this tree just created or replaced.
    private func adopt(_ relative: String, parent: String?) throws -> Entry {
        var info = stat()
        guard lstat(try absolute(relative), &info) == 0 else { throw Self.failure(errno: errno) }
        guard let entry = Self.entry(relative, parent: parent, info: info) else { throw Failure.unsupported }
        try commit(entries.merging([entry.id: entry]) { _, new in new })
        return entry
    }

    private func refreshed(_ known: Entry) -> Entry? {
        var info = stat()
        guard !known.path.isEmpty, let path = try? absolute(known.path),
              lstat(path, &info) == 0, String(info.st_ino) == known.id else { return nil }
        return Self.entry(known.path, parent: known.parent, info: info)
    }

    private func list(_ relative: String, parent: String?) throws -> [Entry] {
        let directory = try absolute(relative)
        // A folder that became a link since it was recorded is not listed
        // through: the link's target may be anywhere.
        guard try FilaPath.resolve(directory) == directory else { throw Failure.missing }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory) }
        catch { throw Self.failure(error) }
        return names.compactMap { name in
            guard !name.hasPrefix(Self.temporaryPrefix) else { return nil }
            var info = stat()
            guard lstat(FilaPath.join(directory, name), &info) == 0 else { return nil }
            return Self.entry(relative.isEmpty ? name : relative + "/" + name, parent: parent, info: info)
        }
    }

    private func rescan() throws {
        var next: [String: Entry] = [:]
        func walk(_ relative: String, parent: String?) throws {
            for entry in try list(relative, parent: parent) {
                next[entry.id] = entry
                if entry.isDirectory { try walk(entry.path, parent: entry.id) }
            }
        }
        try walk("", parent: nil)
        try commit(next)
        lastRescan = Date()
    }

    private func commit(_ next: [String: Entry]) throws {
        guard next != entries else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: index, options: .atomic)
        history.insert((anchor, entries), at: 0)
        history = Array(history.prefix(Self.historyLimit))
        entries = next
    }

    private static func digest(_ entries: [String: Entry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(entries.values.sorted { $0.id < $1.id })) ?? Data()
        return Data(SHA256.hash(data: bytes))
    }

    private static func entry(_ path: String, parent: String?, info: stat) -> Entry? {
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        guard isDirectory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { return nil }
        let name = (path as NSString).lastPathComponent
        return Entry(
            id: String(info.st_ino),
            parent: parent,
            path: path,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : info.st_size,
            created: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            contentVersion: isDirectory ? "directory" : "\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
            metadataVersion: "\(name)|\(parent ?? "")|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        )
    }

    private static func failure(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let fila = error as? FilaFailure { return failure(errno: fila.systemError) }
        if let posix = error as? POSIXError { return failure(errno: posix.code.rawValue) }
        if let cocoa = error as? CocoaError, let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return failure(errno: Int32(underlying.code))
        }
        return .io(EIO)
    }

    private static func failure(errno code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR: return .missing
        case EEXIST: return .collision
        case ENOTEMPTY: return .directoryNotEmpty
        case ENOTSUP: return .unsupported
        case EACCES, EPERM, EROFS: return .permission
        case ENOSPC, EDQUOT: return .noSpace
        case ENAMETOOLONG, EINVAL: return .invalidName
        default: return .io(code)
        }
    }
}
