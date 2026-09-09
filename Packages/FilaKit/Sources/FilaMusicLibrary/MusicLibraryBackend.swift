import FilaBackendKit
import FilaClient
import FilaLog
import Foundation

/// What the music library needs from the file layer: staging a source into
/// a private workspace, publishing bytes into the library's own directory
/// as a job, and taking a failed publication back. The app supplies it over
/// its operation centre, so every import shows up as a task.
public protocol MusicLibraryFiles: Sendable {
    /// The local file layer, for the directory checks and the new-item
    /// defaults on a published file.
    var access: any LocalFileAccess { get }
    /// A copy of `path` in a workspace the caller removes when done.
    func stage(_ path: String) async throws -> URL
    /// A copy job of `source` into `directory`, awaited to its verdict.
    func copy(_ source: URL, into directory: String, subtitle: String) async throws
    /// A permanent delete job for one path, awaited; a missing path is not
    /// a failure.
    func delete(_ path: String, subtitle: String) async throws
}

/// The device's music library as a catalogue backend.
///
/// It owns nothing but its root row and its change hints: the library
/// itself is MediaPlayer's, edited through `MusicLibraryEditor`. Its row
/// appears only where a library exists, and never as a favourite.
@MainActor
public final class MusicLibraryBackend: Backend {
    public nonisolated static let libraryDirectory = "/var/mobile/Media/iTunes_Control"

    public let id = BackendID.musicLibrary
    public let root: BackendRoot
    private let libraryExists: () -> Bool
    /// The file layer imports go through. Nil when no local backend exists
    /// to publish into the library's directory: the library is then offered
    /// read-only, and an import reports that as an ordinary failure.
    public var files: (any MusicLibraryFiles)?
    private var subscribers: [UUID: AsyncStream<BackendSidebar>.Continuation] = [:]
    private var changeSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    nonisolated static var bundle: Bundle { Bundle(for: MusicLibraryBackend.self) }

    /// `libraryExists` answers whether a library is on this device; the
    /// default looks for the library directory.
    public init(libraryExists: @escaping () -> Bool = {
        FileManager.default.fileExists(atPath: MusicLibraryBackend.libraryDirectory)
    }) {
        self.libraryExists = libraryExists
        root = BackendRoot(
            location: .root(of: .musicLibrary),
            kind: .catalog,
            displayName: String(localized: "Music", bundle: MusicLibraryBackend.bundle),
            symbolName: "music.note",
            artworkName: "music"
        )
    }

    public func sidebarUpdates() -> AsyncStream<BackendSidebar> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[token] = nil }
            }
            continuation.yield(sidebar())
        }
    }

    public func sidebar() -> BackendSidebar {
        guard libraryExists() else { return .empty }
        return BackendSidebar(places: [SidebarRow(id: "root", location: root.location, path: nil, kind: .root)])
    }

    /// The library changed, or may have: MediaPlayer said so, the app came
    /// back to the foreground, an import or a delete finished here.
    public func libraryChanged() {
        for continuation in changeSubscribers.values {
            continuation.yield(())
        }
    }

    /// The initial hint at once, then one per `libraryChanged`.
    public func changes() -> AsyncStream<Void> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            changeSubscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeSubscribers[token] = nil }
            }
            continuation.yield(())
        }
    }
}
