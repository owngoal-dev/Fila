import FilaProtocol
import SnapKit
import Then
import UIKit

/// Display metadata only. FileNode names remain the identifiers used by every operation.
struct AppFolderPresentation {
    let name: String
    let detail: String?
    let applicationIdentifier: String?
}

@MainActor
enum AppFolderDisplay {
    private static let dataRoot = "/var/mobile/Containers/Data/Application"
    private static let bundleRoot = "/var/containers/Bundle/Application"
    private static let groupRoot = "/var/mobile/Containers/Shared/AppGroup"

    static func load(in directory: String, entries: [FileNode], session: FileSession) async -> [String: AppFolderPresentation] {
        let root = displayPath(directory)
        guard [dataRoot, bundleRoot, groupRoot].contains(root)
            || entries.contains(where: { $0.kind == .directory && URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "app" }) else { return [:] }
        let apps = await InstalledAppCatalog.load(session: session)
        guard !Task.isCancelled else { return [:] }
        var result = presentations(for: apps).reduce(into: [String: AppFolderPresentation]()) { matches, entry in
            let url = URL(fileURLWithPath: entry.key, isDirectory: true)
            guard url.deletingLastPathComponent().path == root else { return }
            matches[url.lastPathComponent] = entry.value
        }
        // LaunchServices knows the apps it launches. Containers of extensions,
        // of system services and of apps since removed are not among them, but
        // every container says whose it is in its own metadata plist, so the
        // rest are named from that — by the installed app's name where the
        // identifier is an app's, else by the identifier itself.
        guard [dataRoot, groupRoot, bundleRoot].contains(root) else { return result }
        let byIdentifier = Dictionary(apps.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries where entry.kind == .directory && result[entry.name] == nil {
            guard !Task.isCancelled else { return result }
            guard let identifier = await containerIdentifier(at: root + "/" + entry.name, session: session) else { continue }
            let owner = byIdentifier[identifier]
            result[entry.name] = AppFolderPresentation(
                name: owner?.name ?? (root == groupRoot ? identifier : InstalledApp.name(identifier: identifier)),
                detail: owner == nil && root != groupRoot ? identifier : nil,
                applicationIdentifier: owner?.bundleIdentifier ?? (root == groupRoot ? nil : identifier)
            )
        }
        return result
    }

    /// Container identity is stable for the life of the directory; read once.
    private static var containerIdentifiers: [String: String?] = [:]

    /// `MCMMetadataIdentifier` from the container manager's own record inside
    /// the directory: the bundle identifier for a data container, the group
    /// identifier for a shared one. Read through the daemon — the file is
    /// root-owned — and small: a few hundred bytes.
    private static func containerIdentifier(at path: String, session: FileSession) async -> String? {
        if let cached = containerIdentifiers[path] { return cached }
        let metadata = path + "/.com.apple.mobile_container_manager.metadata.plist"
        let identifier: String? = await {
            guard let data = try? await session.read(metadata, limit: 64 * 1024),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String, !identifier.isEmpty else { return nil }
            return identifier
        }()
        containerIdentifiers[path] = .some(identifier)
        return identifier
    }

    static func presentation(for path: String, apps: [InstalledApp]) -> AppFolderPresentation? {
        presentationLookup(for: apps)(path)
    }

    /// One table for many lookups: a breadcrumb asks once per crumb, and the
    /// table is a walk over every installed app.
    static func presentationLookup(for apps: [InstalledApp]) -> (String) -> AppFolderPresentation? {
        let table = presentations(for: apps)
        return { table[displayPath($0)] }
    }

    private static func presentations(for apps: [InstalledApp]) -> [String: AppFolderPresentation] {
        var matches: [String: [(app: InstalledApp, group: String?)]] = [:]
        for app in apps {
            var containers: [(path: String, group: String?)] = [(app.bundlePath, nil)]
            let bundleContainer = URL(fileURLWithPath: displayPath(app.bundlePath)).deletingLastPathComponent()
            if bundleContainer.deletingLastPathComponent().path == bundleRoot {
                containers.append((bundleContainer.path, nil))
            }
            if let dataPath = app.dataPath { containers.append((dataPath, nil)) }
            containers += app.groupPaths.map { ($0.value, $0.key) }
            for container in containers {
                matches[displayPath(container.path), default: []].append((app, container.group))
            }
        }
        return matches.mapValues { owners in
            let names = Set(owners.map { $0.app.name }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let groups = Set(owners.compactMap(\.group)).sorted()
            let identifiers = Set(owners.map { $0.app.bundleIdentifier })
            return AppFolderPresentation(
                name: (groups.isEmpty ? names : groups).joined(separator: ", "),
                detail: groups.isEmpty ? nil : names.joined(separator: ", "),
                applicationIdentifier: identifiers.count == 1 ? identifiers.first : nil
            )
        }
    }

    /// These aliases affect lookup labels only; they never decide permission or operation paths.
    private static func displayPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private static let icons: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    /// What a row shows for an app with no artwork, and while artwork loads.
    static let placeholderIcon = UIImage(systemName: "app.fill")

    /// Artwork already fetched, or nil. A cell paints from here on the scroll
    /// tick and asks `icon(for:)` for whatever is missing.
    static func cachedIcon(for identifier: String?) -> UIImage? {
        guard let identifier else { return placeholderIcon }
        return icons.object(forKey: identifier as NSString)
    }

    /// System-rendered artwork, fetched off the main actor so IconServices'
    /// cache lookup and rendering do not stall scrolling.
    static func icon(for identifier: String?) async -> UIImage? {
        guard let identifier else { return placeholderIcon }
        if let image = icons.object(forKey: identifier as NSString) { return image }
        let scale = UIScreen.main.scale
        let image = await Task.detached(priority: .userInitiated) {
            ApplicationIconRenderer.image(for: identifier, scale: scale)
        }.value
        if let image { icons.setObject(image, forKey: identifier as NSString) }
        return image ?? placeholderIcon
    }

}

/// A hook's peek is its application artwork and real location, never a file
/// preview request for the container. Committing it browses this original path.
final class AppFolderPreviewViewController: UIViewController {
    let path: String
    private let presentation: AppFolderPresentation

    init(path: String, presentation: AppFolderPresentation) {
        self.path = path
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let image = UIImageView(image: AppFolderDisplay.cachedIcon(for: presentation.applicationIdentifier) ?? AppFolderDisplay.placeholderIcon).then {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .systemBrown
            $0.isAccessibilityElement = false
        }
        Task { [weak image, identifier = presentation.applicationIdentifier] in
            let artwork = await AppFolderDisplay.icon(for: identifier)
            image?.image = artwork
        }
        let name = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .headline)
            $0.textColor = .systemBrown
            $0.text = presentation.name
        }
        let detail = UILabel().then {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.text = presentation.detail
            $0.textColor = .secondaryLabel
            $0.isHidden = presentation.detail == nil
        }
        let location = UILabel().then {
            $0.font = FilaUI.Font.monospacedFootnote
            $0.text = path
            $0.textColor = .secondaryLabel
        }
        for label in [name, detail, location] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [image, name, detail, location]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.medium
        }
        view.addSubview(stack)
        image.snp.makeConstraints { make in
            make.width.equalTo(96)
            make.height.equalTo(image.snp.width)
        }
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(FilaUI.Spacing.large)
            make.trailing.equalToSuperview().offset(-FilaUI.Spacing.large)
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.bottom.lessThanOrEqualToSuperview().offset(-FilaUI.Spacing.large)
        }
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: 320 - 2 * FilaUI.Spacing.large, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        preferredContentSize = CGSize(width: 320, height: size.height + 2 * FilaUI.Spacing.large)
    }
}
