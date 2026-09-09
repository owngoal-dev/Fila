import Foundation

/// Where a backend keeps what it remembers between launches.
///
/// Injected by the composition root, never reached for: a backend does not
/// know whether it is writing `UserDefaults`, a test's dictionary or nothing
/// at all. The storage translates one persisted representation; the backend
/// owns defaults, ordering, deduplication, limits and when to save. `load`
/// distinguishes *nothing stored* (nil) from *stored empty* — a user who
/// removed every default favourite must not get them back on the next
/// launch.
///
/// A failed decode reports the failure and leaves the stored bytes alone; it
/// never quietly replaces a user's bookmarks with the defaults.
@MainActor
public protocol DefaultStorage<Value> {
    associatedtype Value: Codable

    func load() throws -> Value?
    func save(_ value: Value) throws
}

/// One `Codable` record under one key, JSON-encoded. The shape for every new
/// scope — a saved SMB share, an FTP root — where there is no legacy layout
/// to keep. Two backends given two keys can never read-modify-write each
/// other's record.
@MainActor
public final class UserDefaultsStorage<Value: Codable>: DefaultStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}

/// Storage that forgets at the end of the process. For tests, and for a
/// backend that has nowhere to persist.
@MainActor
public final class MemoryStorage<Value: Codable>: DefaultStorage {
    public private(set) var stored: Value?
    public private(set) var saveCount = 0
    /// Set to make the next `save` or `load` fail, the way a full disk or a
    /// corrupt record would.
    public var failure: Error?

    public init(_ initial: Value? = nil) {
        stored = initial
    }

    public func load() throws -> Value? {
        if let failure { throw failure }
        return stored
    }

    public func save(_ value: Value) throws {
        if let failure { throw failure }
        stored = value
        saveCount += 1
    }
}
