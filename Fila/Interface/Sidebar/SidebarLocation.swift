import FilaClient
import FilaProtocol
import Foundation

/// A fixed destination in the sidebar's jump list.
struct SidebarLocation: Hashable {
    enum Position: Int, CaseIterable {
        // Persisted in AppPreferences; keep these identities stable when adding presets.
        case root = 0, bootstrap = 1, applications = 2, mobile = 3
        case pictures = 4, music = 5, inbox = 6, trash = 7
    }

    let position: Position
    let title: String
    let icon: FilePresentation.Icon
    let path: String
}

extension SidebarLocation {
    enum Destination {
        case directory(SidebarLocation), applications, music

        var position: Position {
            switch self {
            case let .directory(place): place.position
            case .applications: .applications
            case .music: .music
            }
        }
    }

    @MainActor static var orderedDestinations: [Destination] {
        var destinations = jumpList(backend: FileSession.shared.hello?.backend).map(Destination.directory)
        if SystemCapabilities.showsApplications { destinations.append(.applications) }
        if FileManager.default.fileExists(atPath: "/var/mobile/Media/iTunes_Control") { destinations.append(.music) }
        let available = Dictionary(uniqueKeysWithValues: destinations.map { ($0.position, $0) })
        let preferences = AppPreferences.shared
        return preferences.presetOrder.filter { preferences.isPresetEnabled($0) }.compactMap { available[$0] }
    }

    /// The filesystem places worth one tap on a jailbroken device, plus the bootstrap
    /// root when there is one, and the trash.
    ///
    /// The bootstrap prefix is never written down here: roothide randomizes it
    /// and rootless fixes it at `/var/jb`, so it comes from the daemon's own
    /// `hello` and is simply absent on a rootful layout.
    static func jumpList(backend: DaemonLink.Backend?) -> [SidebarLocation] {
        guard let backend else { return [] }
        let inbox = SidebarLocation(
            position: .inbox,
            title: String(localized: "Inbox"),
            icon: .artwork("inbox"),
            path: inboxDirectory
        )
        if case .local(.container) = backend {
            return [
                SidebarLocation(
                    position: .root,
                    title: String(localized: "Home"),
                    icon: .artwork("home"),
                    path: NSHomeDirectory()
                ),
                inbox,
            ]
        }
        let installRoot: String? = if case let .daemon(root) = backend {
            root
        } else {
            nil
        }
        var places = [
            SidebarLocation(
                position: .root,
                title: String(localized: "Root"),
                icon: .artwork("drive-internal"),
                path: "/"
            ),
            SidebarLocation(
                position: .mobile,
                title: String(localized: "Mobile"),
                icon: .artwork("home"),
                path: "/var/mobile"
            ),
            SidebarLocation(
                position: .pictures,
                title: String(localized: "Pictures"),
                icon: .artwork("pictures"),
                path: "/var/mobile/Media/DCIM"
            ),
            inbox,
        ]
        if let installRoot, !installRoot.isEmpty {
            places.insert(
                SidebarLocation(
                    position: .bootstrap,
                    title: String(localized: "Bootstrap"),
                    icon: .artwork("bootstrap"),
                    path: installRoot
                ),
                at: 1
            )
        }
        // Checked rather than assumed, for the same reason `launchDirectory`
        // checks it: the Mac development loop has no `/var/mobile`, and a jump
        // list offering somewhere that does not exist sends the user to an
        // empty folder that looks like the daemon being broken.
        places = places.filter { FileManager.default.fileExists(atPath: $0.path) }
        // Not filtered: the trash is root-owned 0700 on a daemon, so the app
        // cannot see whether it exists, and the daemon lists it fine.
        places.append(SidebarLocation(
            position: .trash,
            title: String(localized: "Trash"),
            icon: .artwork("trash"),
            path: trashDirectory(backend: backend)
        ))
        return places
    }

    /// Where the system puts a file shared into Fila — *Copy to Fila* — and
    /// where one stays until it is moved somewhere. Inside the app's own
    /// container, which is the one place every backend can write, so it is
    /// made here rather than waiting for the first share to make it.
    static var inboxDirectory: String {
        let inbox = NSHomeDirectory() + "/Documents/Inbox"
        try? FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Matches the backend's trash: under a relocated bootstrap, otherwise
    /// under the requested volume (the data volume for the sidebar).
    static func trashDirectory(backend: DaemonLink.Backend, volume: String = "/private/var") -> String {
        if case let .daemon(root) = backend, !root.isEmpty {
            return FilaTrash.directory(under: root)
        }
        return FilaTrash.directory(under: volume)
    }
}
