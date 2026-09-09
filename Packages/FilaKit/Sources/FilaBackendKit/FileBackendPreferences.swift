import Foundation

public enum FileSortKey: String, CaseIterable, Codable, Sendable {
    case name
    case date
    case size
    case kind
}

public enum BrowserLayout: String, CaseIterable, Codable, Sendable {
    case list
    case grid
}

/// What a file backend remembers for its root: bookmarks, history and how
/// its listings are shown. One value per backend, loaded once, owned by the
/// backend and written back through its `DefaultStorage`.
///
/// Every path is relative to the backend's root, so a saved value survives a
/// container whose installation path changed, and a favourite on one share
/// can never be read as a path on another. Absent (`nil`) favourites mean the
/// user never touched them and the backend's defaults apply; an empty array
/// means they removed every one.
public struct FileBackendPreferences: Codable, Equatable, Sendable {
    public struct Visit: Codable, Equatable, Sendable {
        public var path: ServicePath
        /// Nil for history recorded before visits carried a time. Never
        /// invented: an undated visit stays undated.
        public var visited: Date?

        public init(path: ServicePath, visited: Date?) {
            self.path = path
            self.visited = visited
        }
    }

    public var favorites: [ServicePath]?
    /// Newest first.
    public var recents: [Visit]
    public var lastDirectory: ServicePath?
    public var sortKey: FileSortKey
    public var sortAscending: Bool
    public var showsHidden: Bool
    /// The view a folder gets when it has no opinion of its own.
    public var layout: BrowserLayout
    public var folderLayouts: [ServicePath: BrowserLayout]

    public init(
        favorites: [ServicePath]? = nil,
        recents: [Visit] = [],
        lastDirectory: ServicePath? = nil,
        sortKey: FileSortKey = .name,
        sortAscending: Bool = true,
        showsHidden: Bool = false,
        layout: BrowserLayout = .list,
        folderLayouts: [ServicePath: BrowserLayout] = [:]
    ) {
        self.favorites = favorites
        self.recents = recents
        self.lastDirectory = lastDirectory
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.showsHidden = showsHidden
        self.layout = layout
        self.folderLayouts = folderLayouts
    }

    /// How many visits are kept. A sidebar shows a handful; the rest is a
    /// trail in a plist any root process can read, so it stays short.
    public static let recentLimit = 40
    /// How many folders may remember their own view. See `setLayout`.
    public static let folderLayoutLimit = 200

    /// Records a visit at the front, dropping any earlier visit to the same
    /// place, and trims to the limit.
    public mutating func noteVisit(_ path: ServicePath, at date: Date) {
        recents.removeAll { $0.path == path }
        recents.insert(Visit(path: path, visited: date), at: 0)
        if recents.count > Self.recentLimit {
            recents.removeLast(recents.count - Self.recentLimit)
        }
    }

    /// The layout for one folder: its own if it has one, the default
    /// otherwise.
    public func layout(for path: ServicePath) -> BrowserLayout {
        folderLayouts[path] ?? layout
    }

    /// The default follows the most recent choice, so a folder with no
    /// opinion of its own looks like the last one that did. The map is
    /// dropped wholesale when it overflows rather than evicting by age:
    /// the cost of being wrong is that some folders forget their view.
    public mutating func setLayout(_ value: BrowserLayout, for path: ServicePath) {
        layout = value
        if folderLayouts.count >= Self.folderLayoutLimit, folderLayouts[path] == nil {
            folderLayouts = [:]
        }
        folderLayouts[path] = value
    }
}
