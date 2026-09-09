import UIKit

@MainActor
enum FilaMenu {
    static func groups(_ groups: [UIMenuElement]...) -> [UIMenuElement] {
        groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
    }

    /// Navigation uses the same ordered folder destinations and previews as Places.
    static func destinations(
        goToPath: @escaping () -> Void,
        open: @escaping (String) -> Void
    ) -> [UIMenuElement] {
        let places = SidebarLocation.orderedDestinations.compactMap { destination -> UIMenuElement? in
            guard case let .directory(place) = destination else { return nil }
            return UIAction(title: place.title, image: preview(for: place)) { _ in open(place.path) }
        }
        let locations = [UIMenu(
            title: String(localized: "Places"),
            image: UIImage(named: "FileIcons/folder"),
            children: places
        )]
            + collections(open: open)
        let path = UIAction(title: String(localized: "Go to Path…")) { _ in goToPath() }
        return groups(locations, [path])
    }

    static func preview(for place: SidebarPlace) -> UIImage? {
        switch place.icon {
        case let .artwork(name): UIImage(named: "FileIcons/\(name)")?.withRenderingMode(.alwaysOriginal)
        case .symbol: FilePresentation.image(kind: .directory, name: place.title)
        }
    }

    static func collections(attributes: UIMenuElement.Attributes = [], open: @escaping (String) -> Void) -> [UIMenu] {
        let session = FileSession.shared
        func folders(_ paths: [String], limit: Int? = nil) -> UIDeferredMenuElement {
            UIDeferredMenuElement.uncached { completion in
                Task { @MainActor in
                    let session = FileSession.shared
                    let apps = await InstalledAppCatalog.load(session: session)
                    var actions: [UIMenuElement] = []
                    for path in paths {
                        guard let details = try? await session.perform({ try await $0.details(of: path) }),
                              details.node.isNavigable else { continue }
                        let presentation = AppFolderDisplay.presentation(for: path, apps: apps)
                        var image = FilePresentation.image(for: details.node)
                        if let identifier = presentation?.applicationIdentifier {
                            image = await AppFolderDisplay.icon(for: identifier) ?? image
                        }
                        let name = presentation?.name ?? (path == "/" ? "/" : (path as NSString).lastPathComponent)
                        actions.append(UIAction(
                            title: name,
                            subtitle: path,
                            image: image,
                            attributes: attributes
                        ) { _ in open(path) })
                        if let limit, actions.count == limit { break }
                    }
                    completion(actions)
                }
            }
        }
        let mounts = UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                let mounts = (try? await FileSession.shared.perform { try await $0.mountPoints() }) ?? []
                completion(mounts.map { mount in
                    let name = mount.path == "/"
                        ? String(localized: "Root")
                        : (mount.path as NSString).lastPathComponent
                    return UIAction(
                        title: name,
                        subtitle: mount.path,
                        image: UIImage(named: "FileIcons/drive-internal")?.withRenderingMode(.alwaysOriginal),
                        attributes: attributes
                    ) { _ in open(mount.path) }
                })
            }
        }
        return [
            UIMenu(
                title: String(localized: "Favorites"),
                image: UIImage(named: "FileIcons/folder"),
                children: [folders(session.favoritePaths)]
            ),
            UIMenu(
                title: String(localized: "Mount Points"),
                image: UIImage(named: "FileIcons/drive-internal"),
                children: [mounts]
            ),
            UIMenu(
                title: String(localized: "Recents"),
                image: UIImage(named: "FileIcons/folder"),
                children: [folders(session.recentPaths(limit: 8))]
            ),
        ]
    }

    /// Palettes suit a small set of mutually exclusive, recognizable icons.
    /// Keep the same action titles and selection state on older systems.
    static func selection(title: String, actions: [UIAction]) -> UIMenu {
        var options: UIMenu.Options = [.displayInline, .singleSelection]
        if #available(iOS 17.0, *) {
            options.insert(.displayAsPalette)
        }
        return UIMenu(title: title, options: options, children: actions)
    }
}
