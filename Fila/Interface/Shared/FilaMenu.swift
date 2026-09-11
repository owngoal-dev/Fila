import FilaBackendUI
import FilaBackendKit
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
        let directories = SidebarLocation.orderedDestinations.compactMap { destination -> SidebarPlace? in
            guard case let .directory(place) = destination else { return nil }
            return place
        }
        let places = directories.map { place in
            UIAction(title: place.title, image: preview(for: place)) { _ in open(place.path) }
        }
        let locations = [UIMenu(
            title: String(localized: "Places"),
            image: compositeIcon(directories.compactMap(preview(for:))) ?? FilePresentation.image(for: .device(.folder)),
            children: places
        )]
            + collections(open: open)
        let path = UIAction(title: String(localized: "Go to Path…")) { _ in goToPath() }
        return groups(locations, [path])
    }

    static func preview(for place: SidebarPlace) -> UIImage? {
        FilePresentation.image(for: place.icon)
    }

    /// A menu row's picture side: a composed icon is drawn at 40 points so it
    /// sits in a menu row the way its siblings do.
    private static let rowIconSide: CGFloat = 40

    /// A submenu's icon composed from what it holds — a square grid of the
    /// first pictures inside it on a rounded tile — so a row that opens a
    /// list says what kind of list, rather than showing the same folder for
    /// Places, Favorites and Recents alike. Exactly three shapes: one
    /// picture fills the tile, nine or more make a 3×3 of the first nine,
    /// and anything between is a 2×2 of the first four — with two or three
    /// pictures the remaining cells stay empty, because a 2×1 or a 3×2 is
    /// a different tile beside its siblings. Nil for an empty list, and the
    /// caller falls back to the plain folder.
    static func compositeIcon(_ pictures: [UIImage]) -> UIImage? {
        guard !pictures.isEmpty else { return nil }
        let columns = pictures.count == 1 ? 1 : pictures.count >= 9 ? 3 : 2
        let pictures = Array(pictures.prefix(columns * columns))
        let side = rowIconSide
        let inset: CGFloat = 3
        let gap: CGFloat = 2
        let cell = (side - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let top = inset
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        // Rendered on every open of the menu (the callers are deferred
        // elements), so the fill resolves for the current appearance.
        let image = UIGraphicsImageRenderer(size: tile.size).image { _ in
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: tile, cornerRadius: side * 0.22).fill()
            for (index, picture) in pictures.enumerated() {
                let box = CGRect(
                    x: inset + CGFloat(index % columns) * (cell + gap),
                    y: top + CGFloat(index / columns) * (cell + gap),
                    width: cell,
                    height: cell
                )
                // Aspect fit: the artwork is square, but a symbol is not.
                let scale = min(box.width / max(picture.size.width, 1), box.height / max(picture.size.height, 1))
                let size = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
                picture.draw(in: CGRect(
                    x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height
                ))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private static func folderIcon(named name: String) -> UIImage? {
        FilePresentation.image(kind: .directory, name: (name as NSString).lastPathComponent)
    }

    static func collections(attributes: UIMenuElement.Attributes = [], open: @escaping (String) -> Void) -> [UIMenu] {
        let session = FileSession.shared
        func folders(_ paths: [String], limit: Int? = nil) -> UIDeferredMenuElement {
            UIDeferredMenuElement.uncached { completion in
                Task { @MainActor in
                    let session = FileSession.shared
                    let decoration = await SystemCapabilities.applications?.decorationLookup() ?? { _ in nil }
                    var actions: [UIMenuElement] = []
                    for path in paths {
                        guard let details = try? await session.perform({ try await $0.details(of: path) }),
                              details.node.isNavigable else { continue }
                        let presentation = decoration(path)
                        var image = FilePresentation.image(for: details.node)
                        if let identifier = presentation?.applicationIdentifier,
                           let artwork = SystemCapabilities.applicationArtwork
                        {
                            image = await artwork.icon(for: identifier) ?? image
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
        let folder = FilePresentation.image(for: .device(.folder))
        let drive = FilePresentation.image(for: .artwork("drive-internal"))
        let favorites = session.favoritePaths
        let recents = session.recentPaths(limit: 8)
        return [
            UIMenu(
                title: String(localized: "Favorites"),
                image: compositeIcon(favorites.compactMap(folderIcon(named:))) ?? folder,
                children: [folders(favorites)]
            ),
            UIMenu(
                // The mounts are listed when the menu opens; the tile says
                // "volumes" with the drive picture, four up.
                title: String(localized: "Mount Points"),
                image: compositeIcon(Array(repeating: drive, count: 4).compactMap(\.self)) ?? drive,
                children: [mounts]
            ),
            UIMenu(
                title: String(localized: "Recents"),
                image: compositeIcon(recents.compactMap(folderIcon(named:))) ?? folder,
                children: [folders(recents)]
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
