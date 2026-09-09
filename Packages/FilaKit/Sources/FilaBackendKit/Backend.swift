import Foundation

/// The stable identity of a logical backend: the local filesystem, one saved
/// SMB share, one FTP starting directory, the installed-application catalogue.
///
/// This is the key every backend-scoped preference, sidebar row and tab is
/// filed under, so it must not change when a display name, a credential or a
/// connection object does. Remote backends derive it from their saved profile
/// ID, never from a hostname.
public struct BackendID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// A place inside a backend: the backend plus an opaque, backend-owned item
/// identity. A file backend puts its service-relative path here; a catalogue
/// backend a bundle identifier or a persistent library ID. The shell routes by
/// the backend and never interprets the item.
public struct BackendLocation: Hashable, Codable, Sendable {
    public let backend: BackendID
    /// Backend-owned item identity. The empty string is the backend's root.
    public let item: String

    public init(backend: BackendID, item: String) {
        self.backend = backend
        self.item = item
    }

    public static func root(of backend: BackendID) -> BackendLocation {
        BackendLocation(backend: backend, item: "")
    }

    public var isRoot: Bool { item.isEmpty }
}

/// What a backend is rooted at, with the display metadata the sidebar needs
/// to draw it. The value grants no access: the backend's own authority does.
public struct BackendRoot: Equatable, Sendable {
    /// Whether the root is a directory tree or a catalogue of typed items.
    public enum Kind: String, Sendable {
        case filesystem
        case catalog
    }

    public let location: BackendLocation
    public let kind: Kind
    /// Already localized by the backend that owns it.
    public let displayName: String
    /// The SF Symbol the sidebar shows beside `displayName`.
    public let symbolName: String
    /// A piece of the app's own artwork to prefer over the symbol, by the
    /// name the app files it under; nil draws the symbol.
    public let artworkName: String?

    public init(location: BackendLocation, kind: Kind, displayName: String, symbolName: String, artworkName: String? = nil) {
        self.location = location
        self.kind = kind
        self.displayName = displayName
        self.symbolName = symbolName
        self.artworkName = artworkName
    }
}

public extension BackendID {
    /// The catalogue backends the app's links may name. A link to one of
    /// these is routed through the registry like any other location; with
    /// the module absent the link reports the feature unavailable.
    static let applications = BackendID("applications")
    static let musicLibrary = BackendID("music")
}

/// A long-lived storage source. It outlives any connection: disconnecting an
/// SMB share retires its session, not the backend or its bookmarks.
///
/// Main-actor because its state is UI state; the I/O it hands out is not.
@MainActor
public protocol Backend: AnyObject {
    var id: BackendID { get }
    var root: BackendRoot { get }

    /// This backend's sidebar contribution, as a stream of complete
    /// snapshots: the current one immediately, then a replacement whenever
    /// its preferences or its derived locations change. Every call is an
    /// independent subscription buffering only the newest snapshot, so a
    /// slow reader skips intermediate states and never a final one. The
    /// stream survives a lost connection; only removal of the backend ends
    /// it.
    func sidebarUpdates() -> AsyncStream<BackendSidebar>
}
