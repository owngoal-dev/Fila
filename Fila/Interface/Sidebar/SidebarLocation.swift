import FilaBackendKit
import FilaClient
import Foundation

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
            icon = .artwork("folder")
        case let .named(name):
            title = name
            icon = .artwork("folder")
        }
    }
}

/// The ordered Places section, with the catalogue destinations slotted in
/// by the same preset order the local backend keeps.
enum SidebarLocation {
    enum Destination {
        case directory(SidebarPlace), applications, music
    }

    @MainActor static var orderedDestinations: [Destination] {
        let session = FileSession.shared
        let local = session.local
        let rows = Dictionary(
            uniqueKeysWithValues: BackendComposition.sidebar.contribution(of: local.id).places.map { ($0.id, $0) }
        )
        let showsMusic = FileManager.default.fileExists(atPath: "/var/mobile/Media/iTunes_Control")
        return local.orderedPresets.filter(local.isPresetEnabled).compactMap { preset in
            switch preset {
            case .applications:
                return SystemCapabilities.showsApplications ? .applications : nil
            case .music:
                return showsMusic ? .music : nil
            default:
                return rows[LocalFileBackend.placeID(preset)].map { .directory(SidebarPlace($0, in: local)) }
            }
        }
    }
}
