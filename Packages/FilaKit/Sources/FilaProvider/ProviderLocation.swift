import Darwin
import FilaFileOps
import FilaProtocol
import Foundation

/// A backing folder, separate from File Provider's system-owned materialization URLs.
/// Generations are retained so an editor opened before a location change can save to its source.
///
/// The folder is recorded as a resolved path, not a bookmark. A bookmark
/// resolves by file identity and reports itself stale whenever the canonical
/// path differs from the one it was recorded with, which RootHide's relocated
/// Documents made permanent: the extension never got past `resolve`.
public struct ProviderLocation: Codable, Equatable, Sendable {
    public let generation: UUID
    public let displayPath: String
    public let isDefault: Bool

    public enum Failure: Error {
        case invalidConfiguration, unavailableFolder, recursiveLocation
    }

    public func resolve(in groupURL: URL? = nil) throws -> URL {
        let url = URL(fileURLWithPath: displayPath, isDirectory: true)
        try Self.validateFolder(url, groupURL: groupURL)
        return url
    }

    public static func load(in groupURL: URL) throws -> ProviderLocation? {
        try transaction(in: groupURL) { group, _ in
            try read(group.appendingPathComponent(".fila-provider-location.json"))
        }
    }

    public static func load(generation: UUID, in groupURL: URL) throws -> ProviderLocation? {
        try transaction(in: groupURL) { group, _ in
            let value = try read(historyURL(generation, group: group))
            guard value == nil || value?.generation == generation else { throw Failure.invalidConfiguration }
            return value
        }
    }

    @discardableResult
    public static func initializeDefault(documentsURL: URL, in groupURL: URL) throws -> ProviderLocation {
        try transaction(in: groupURL) { group, operations in
            let current = try read(group.appendingPathComponent(".fila-provider-location.json"))
            if let current, !current.isDefault { return current }
            let path = try FilaPath.resolve(documentsURL.path)
            let generation = current.flatMap { $0.displayPath == path ? $0.generation : nil } ?? UUID()
            let value = try make(url: documentsURL, isDefault: true, generation: generation, group: group)
            try publish(value, group: group, operations: operations)
            return value
        }
    }

    @discardableResult
    public static func bind(to url: URL, isDefault: Bool, in groupURL: URL) throws -> ProviderLocation {
        try transaction(in: groupURL) { group, operations in
            let value = try make(url: url, isDefault: isDefault, generation: UUID(), group: group)
            try publish(value, group: group, operations: operations)
            return value
        }
    }

    private static func make(url: URL, isDefault: Bool, generation: UUID, group: URL) throws -> ProviderLocation {
        try validateFolder(url, groupURL: group)
        return ProviderLocation(generation: generation, displayPath: try FilaPath.resolve(url.path), isDefault: isDefault)
    }

    private static func validateFolder(_ url: URL, groupURL: URL?) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw Failure.unavailableFolder }
        let path = try FilaPath.resolve(url.path)
        if let groupURL {
            let group = URL(fileURLWithPath: try FilaPath.resolve(groupURL.path)).pathComponents
            let selected = URL(fileURLWithPath: path).pathComponents
            guard !selected.starts(with: group), !group.starts(with: selected) else {
                throw Failure.recursiveLocation
            }
        }
        // Only actual OS access to a directory makes it an acceptable backing folder.
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailableFolder }
        Darwin.close(descriptor)
    }

    private static func historyURL(_ generation: UUID, group: URL) -> URL {
        group.appendingPathComponent(".fila-provider-locations", isDirectory: true)
            .appendingPathComponent(generation.uuidString + ".json")
    }

    private static func transaction<T>(in groupURL: URL, _ body: (URL, FileOperations) throws -> T) throws -> T {
        let group = URL(fileURLWithPath: try FilaPath.resolve(groupURL.path), isDirectory: true)
        let operations = FileOperations(bootstrapRoot: group.path, writableRoot: group.path)
        let descriptor = try operations.open(group.appendingPathComponent(".fila-provider-location.lock").path,
                                             flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: 0o600)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid() else { throw Failure.invalidConfiguration }
        guard flock(descriptor, LOCK_EX) == 0 else { throw FilaFailure(errno: errno, path: group.path) }
        defer { flock(descriptor, LOCK_UN) }
        let history = group.appendingPathComponent(".fila-provider-locations", isDirectory: true)
        if lstat(history.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.invalidConfiguration }
            try operations.create(.directory, at: history.path, mode: 0o700)
        }
        guard lstat(history.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw Failure.invalidConfiguration }
        return try body(group, operations)
    }

    private static func read(_ url: URL) throws -> ProviderLocation? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.invalidConfiguration
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 1_048_576 else { throw Failure.invalidConfiguration }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw Failure.invalidConfiguration }
        // Older files carry a `bookmark` key too; the decoder ignores it.
        let value = try JSONDecoder().decode(ProviderLocation.self, from: data)
        guard (try? FilaPath.canonical(value.displayPath)) != nil else { throw Failure.invalidConfiguration }
        return value
    }

    private static func publish(_ value: ProviderLocation, group: URL, operations: FileOperations) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 1_048_576 else { throw Failure.invalidConfiguration }
        // An interruption between these writes leaves the previous current generation usable.
        try write(bytes, to: historyURL(value.generation, group: group), operations: operations)
        try write(bytes, to: group.appendingPathComponent(".fila-provider-location.json"), operations: operations)
    }

    private static func write(_ bytes: Data, to destination: URL, operations: FileOperations) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".fila-location-" + UUID().uuidString)
        let descriptor = try operations.open(temporary.path, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode: 0o600)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            // The exclusive create above establishes ownership; cleanup never touches an unknown node.
            _ = unlink(temporary.path)
        }
        try file.write(contentsOf: bytes)
        try file.synchronize()
        try operations.replaceItem(at: destination.path, withTemporary: temporary.path, permissions: 0o600)
    }
}
