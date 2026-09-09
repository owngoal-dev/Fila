import FilaCore
import Foundation
import UIKit

/// The music module: the device's music library as a catalogue, its list
/// and song screens, and the import path through the app's file layer.
///
/// The library is MediaPlayer's and the edits go through the private bridge
/// in `CFilaMusicLibrary`; this framework, and only this framework, links
/// that bridge, so a build that leaves the framework out carries none of
/// those symbols. Imports publish bytes into the library's own directory,
/// which needs the local backend; without one the module offers the
/// library read-only and the import fails as an ordinary operation.
@objc(FilaMusicLibraryModule)
public final class FilaMusicLibraryModule: NSObject, BackendModule {
    private var backend: MusicLibraryBackend?
    private var local: LocalFileBackend?

    override public required init() {
        super.init()
    }

    public func register(with registration: BackendRegistration) throws {
        try registration.route(.musicLibrary) { [weak self] location in
            guard location.isRoot, let self, let backend else { return nil }
            return MusicLibraryViewController(backend: backend, local: local)
        }
        registration.backends { [weak self] resolver in
            let backend = MusicLibraryBackend()
            let local = resolver.backend(LocalFileBackend.identifier) as? LocalFileBackend
            backend.files = local.map { ShellMusicFiles(access: $0.access) }
            self?.local = local
            self?.backend = backend
            return [backend]
        }
    }
}

/// `MusicLibraryFiles` over the shell: every import is a task in the app's
/// operation centre, and the workspace is the app's own.
@MainActor
final class ShellMusicFiles: MusicLibraryFiles {
    let access: any LocalFileAccess

    init(access: any LocalFileAccess) {
        self.access = access
    }

    private var shell: any BackendShell {
        get throws {
            guard let shell = BackendScreens.shell else { throw MusicShellMissing() }
            return shell
        }
    }

    func stage(_ path: String) async throws -> URL {
        try await shell.stage(path)
    }

    func copy(_ source: URL, into directory: String, subtitle: String) async throws {
        try await shell.copy(source, into: directory, subtitle: subtitle)
    }

    func delete(_ path: String, subtitle: String) async throws {
        try await shell.delete(path, subtitle: subtitle)
    }

    struct MusicShellMissing: Error {}
}
