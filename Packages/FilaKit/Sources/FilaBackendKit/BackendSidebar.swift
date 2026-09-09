import Foundation

/// One backend's complete, immutable contribution to the sidebar.
///
/// A projection of the backend's loaded preferences and its capabilities,
/// not a store: rows are rebuilt from the authority whenever it changes and
/// the app merges every backend's contribution into the shared sections. A
/// catalogue backend contributes its root and nothing else; it has no
/// favourites and no history.
public struct BackendSidebar: Sendable, Equatable {
    /// Fixed destinations, in the backend's own order.
    public let places: [SidebarRow]
    /// User-chosen locations, in the user's order.
    public let favorites: [SidebarRow]
    /// Visited locations, newest first. `visited` is nil for history
    /// recorded before visits carried a time; those sort after dated ones.
    public let recents: [SidebarVisit]

    public init(places: [SidebarRow], favorites: [SidebarRow] = [], recents: [SidebarVisit] = []) {
        self.places = places
        self.favorites = favorites
        self.recents = recents
    }

    public static let empty = BackendSidebar(places: [])
}

/// A sidebar destination as a backend describes it. The app decides the
/// icon and the wording for a `kind`; a backend that names its own row —
/// a share, a saved remote folder — says so with `.named`.
public struct SidebarRow: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The backend's root.
        case root
        /// Jailbreak bootstrap prefix.
        case bootstrap
        /// The user's home (`/var/mobile`, or the container).
        case home
        case pictures
        /// The shared Inbox other apps save into.
        case inbox
        /// The backend's trash.
        case trash
        /// A mounted volume; `readOnly` for a volume nothing can write to.
        case mount(readOnly: Bool)
        /// A saved location the user picked.
        case favorite
        /// A row with its own title, supplied by the backend.
        case named(String)
    }

    /// Stable within the backend; the app scopes it by backend and section.
    public let id: String
    public let location: BackendLocation
    /// The typed path for a file backend's row; nil for a catalogue root.
    public let path: ServicePath?
    public let kind: Kind

    public init(id: String, location: BackendLocation, path: ServicePath?, kind: Kind) {
        self.id = id
        self.location = location
        self.path = path
        self.kind = kind
    }
}

/// One visited location. Deduplicated by the app on the full location.
public struct SidebarVisit: Sendable, Hashable {
    public let location: BackendLocation
    public let path: ServicePath
    public let visited: Date?

    public init(location: BackendLocation, path: ServicePath, visited: Date?) {
        self.location = location
        self.path = path
        self.visited = visited
    }
}
