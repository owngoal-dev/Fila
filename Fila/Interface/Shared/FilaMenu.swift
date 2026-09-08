import UIKit

@MainActor
enum FilaMenu {
    static func groups(_ groups: [UIMenuElement]...) -> [UIMenuElement] {
        groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
    }

    /// Places, favorites and recents, then manual path entry: the *Go* menu.
    /// Every entry is a path and the caller decides what going there means —
    /// the browser re-roots its tab, the save panel walks its own stack.
    /// `includesFiles` keeps the recent files that only a browser can open.
    static func destinations(
        includesFiles: Bool,
        goToPath: @escaping () -> Void,
        open: @escaping (_ path: String, _ isFile: Bool) -> Void
    ) -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        func destination(
            _ path: String,
            title: String,
            image: UIImage?,
            subtitle: String? = nil,
            isFile: Bool = false
        ) -> UIAction {
            UIAction(title: title, subtitle: subtitle, image: image) { _ in open(path, isFile) }
        }
        func name(of path: String) -> String {
            path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent
        }
        let places = SidebarLocation.jumpList(backend: FileSession.shared.hello?.backend).map { place in
            let image: UIImage? = switch place.icon {
            case let .artwork(name): UIImage(named: "FileIcons/\(name)")?.withRenderingMode(.alwaysOriginal)
            case let .symbol(name): UIImage(systemName: name)
            }
            return destination(place.path, title: place.title, image: image)
        }
        let favorites = preferences.favorites.map {
            destination($0, title: name(of: $0), image: UIImage(systemName: "star"), subtitle: $0)
        }
        let recents = preferences.recents
            .filter { includesFiles || !preferences.recentFiles.contains($0) }
            .prefix(8)
            .map {
                destination(
                    $0,
                    title: name(of: $0),
                    image: UIImage(systemName: "clock"),
                    subtitle: $0,
                    isFile: preferences.recentFiles.contains($0)
                )
            }
        let locations = [
            UIMenu(title: String(localized: "Places"), image: UIImage(systemName: "folder"), children: places),
            UIMenu(title: String(localized: "Favorites"), image: UIImage(systemName: "star"), children: favorites),
            UIMenu(title: String(localized: "Recents"), image: UIImage(systemName: "clock"), children: recents),
        ].filter { !$0.children.isEmpty }
        let path = UIAction(
            title: String(localized: "Go to Path…"),
            image: UIImage(systemName: "arrow.right.circle")
        ) { _ in goToPath() }
        // Named destinations come first; manual path entry stays last.
        return groups(locations, [path])
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
