import FilaBackendKit
import FilaClient
import Foundation
import UIKit

/// A destination in the sidebar's jump list, as the app draws it: the
/// backend said what kind of place it is; the wording and the artwork are
/// the app's.
struct SidebarPlace: Hashable {
    let backend: BackendID
    let id: String
    let path: String
    let title: String
    let icon: FilePresentation.Icon

    /// `besideBootstrapHome`: the bootstrap's own `mobile` is listed too, so
    /// the system's says which of the two it is.
    @MainActor
    init(_ row: SidebarRow, in backend: LocalFileBackend, besideBootstrapHome: Bool = false) {
        self.backend = backend.id
        id = row.id
        path = row.path.map(backend.absolutePath) ?? backend.rootPath
        switch row.kind {
        case .root:
            title = String(localized: "Root")
            icon = .artwork("drive-internal")
        case .home:
            // The container's Documents in a sandboxed process, the user's
            // home on a device that can see it.
            if row.id == LocalFileBackend.placeID(.root) {
                title = String(localized: "Home")
            } else if besideBootstrapHome {
                title = String(localized: "Mobile (System)")
            } else {
                title = String(localized: "Mobile")
            }
            icon = .artwork("home")
        case .bootstrapHome:
            title = String(localized: "Mobile (Bootstrap)")
            icon = .artwork("home")
        case .bootstrap:
            title = String(localized: "Bootstrap")
            icon = .artwork("bootstrap")
        case .pictures:
            title = String(localized: "Pictures")
            icon = .artwork("pictures")
        case .inbox:
            title = String(localized: "Inbox")
            icon = .artwork("inbox")
        case .trash:
            title = String(localized: "Trash")
            icon = .artwork("trash")
        case let .mount(readOnly):
            title = (path as NSString).lastPathComponent + (readOnly ? " · " + String(localized: "Read Only") : "")
            icon = .artwork("drive-internal")
        case .favorite:
            title = (path as NSString).lastPathComponent
            icon = .artwork("folder")
        case let .named(name):
            title = name
            icon = .artwork("folder")
        }
    }
}

/// The ordered Places section, with the catalogue destinations slotted in
/// by the same preset order the local backend keeps.
///
/// A catalogue backend — applications, music — contributes its root row
/// only while it has something to show; the row's artwork and wording are
/// the backend's own, and the shell opens it through the module's screen
/// route rather than any concrete type.
enum SidebarLocation {
    enum Destination {
        case directory(SidebarPlace)
        case catalog(BackendRoot)
    }

    @MainActor static var orderedDestinations: [Destination] {
        let session = FileSession.shared
        let local = session.local
        let rows = Dictionary(
            uniqueKeysWithValues: BackendComposition.sidebar.contribution(of: local.id).places.map { ($0.id, $0) },
        )
        let bootstrapHome = rows[LocalFileBackend.bootstrapHomeID]
        return local.orderedPresets.filter(local.isPresetEnabled).flatMap { preset -> [Destination] in
            switch preset {
            case .applications:
                return [catalog(.applications)].compactMap(\.self)
            case .music:
                return [catalog(.musicLibrary)].compactMap(\.self)
            case .mobile:
                // The bootstrap's own `mobile` rides this preset, directly
                // under the system's, and the two are worded apart.
                let system = rows[LocalFileBackend.placeID(preset)].map {
                    SidebarPlace($0, in: local, besideBootstrapHome: bootstrapHome != nil)
                }
                return [system, bootstrapHome.map { SidebarPlace($0, in: local) }]
                    .compactMap(\.self)
                    .map(Destination.directory)
            default:
                return [rows[LocalFileBackend.placeID(preset)]]
                    .compactMap(\.self)
                    .map { .directory(SidebarPlace($0, in: local)) }
            }
        }
    }

    /// Every remote file backend's root — a saved share — in the order they
    /// were registered or saved.
    @MainActor static var servers: [BackendRoot] {
        let local = FileSession.shared.local.id
        return BackendComposition.registry.backends
            .filter { $0 is any FileBackend && $0.root.kind == .filesystem && $0.id != local }
            .map(\.root)
    }

    /// The root of a catalogue backend, when it is registered and currently
    /// offers its root row.
    @MainActor private static func catalog(_ id: BackendID) -> Destination? {
        guard let backend = BackendComposition.registry.backend(id),
              BackendComposition.sidebar.contribution(of: id).places.contains(where: { $0.kind == .root })
        else { return nil }
        return .catalog(backend.root)
    }

    /// The screen a module routes for `location`, or nil when no module
    /// claims that backend.
    @MainActor static func screen(for location: BackendLocation) -> UIViewController? {
        BackendComposition.registry.screen(for: location) as? UIViewController
    }

    /// The artwork the backend names. A name nothing draws gets the folder
    /// rather than a glyph: the sidebar is pictures throughout, and a symbol
    /// among them reads as a control.
    @MainActor static func image(for root: BackendRoot) -> UIImage? {
        FilePresentation.image(for: .artwork(root.artworkName)) ?? FilePresentation.image(for: .artwork("folder"))
    }
}
