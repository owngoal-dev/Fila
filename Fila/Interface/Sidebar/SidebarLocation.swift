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

    @MainActor
    init(_ row: SidebarRow, in backend: LocalFileBackend) {
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
            title = row.id == LocalFileBackend.placeID(.root) ? String(localized: "Home") : String(localized: "Mobile")
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
            icon = .device(.folder)
        case let .named(name):
            title = name
            icon = .device(.folder)
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
            uniqueKeysWithValues: BackendComposition.sidebar.contribution(of: local.id).places.map { ($0.id, $0) }
        )
        return local.orderedPresets.filter(local.isPresetEnabled).compactMap { preset in
            switch preset {
            case .applications:
                return catalog(.applications)
            case .music:
                return catalog(.musicLibrary)
            default:
                return rows[LocalFileBackend.placeID(preset)].map { .directory(SidebarPlace($0, in: local)) }
            }
        }
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

    /// The picture the backend names (`FilePresentation.Icon.named`). A name
    /// nothing draws gets the OS's folder rather than a glyph: the sidebar
    /// is pictures throughout, and a symbol among them reads as a control.
    @MainActor static func image(for root: BackendRoot) -> UIImage? {
        FilePresentation.image(for: .named(root.artworkName)) ?? FilePresentation.image(for: .device(.folder))
    }
}
