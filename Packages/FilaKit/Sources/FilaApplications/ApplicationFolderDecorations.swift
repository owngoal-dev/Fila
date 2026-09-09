import FilaBackendKit
import FilaClient
import Foundation

/// Names and artwork identities for the directories apps own: their
/// bundles, their data containers and their group containers. Display
/// metadata only; every operation keeps the directory's real name.
public enum ApplicationFolderDecorations {
    static let dataRoot = "/var/mobile/Containers/Data/Application"
    static let bundleRoot = ApplicationCatalog.bundleRoot
    static let groupRoot = "/var/mobile/Containers/Shared/AppGroup"

    /// Decorations for the directories in `directory`, keyed by entry name.
    /// `read` fetches a small file — a container's metadata plist — as the
    /// local layer opens it, root-owned or not.
    static func load(
        in directory: String,
        entries: [(name: String, isDirectory: Bool)],
        apps: [InstalledApp],
        read: (String) async -> Data?
    ) async -> [String: FolderDecoration] {
        let root = displayPath(directory)
        guard [dataRoot, bundleRoot, groupRoot].contains(root)
            || entries.contains(where: {
                $0.isDirectory && URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "app"
            }) else { return [:] }
        var result = presentations(for: apps).reduce(into: [String: FolderDecoration]()) { matches, entry in
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
        for entry in entries where entry.isDirectory && result[entry.name] == nil {
            guard !Task.isCancelled else { return result }
            guard let identifier = await containerIdentifier(at: root + "/" + entry.name, read: read)
            else { continue }
            let owner = byIdentifier[identifier]
            result[entry.name] = FolderDecoration(
                name: owner?.name ?? (root == groupRoot ? identifier : InstalledApp.name(identifier: identifier)),
                detail: owner == nil && root != groupRoot ? identifier : nil,
                applicationIdentifier: owner?.bundleIdentifier ?? (root == groupRoot ? nil : identifier)
            )
        }
        return result
    }

    /// Container identity is stable for the life of the directory; read once.
    private static let identifiers = IdentifierCache()

    /// `MCMMetadataIdentifier` from the container manager's own record inside
    /// the directory: the bundle identifier for a data container, the group
    /// identifier for a shared one. Small: a few hundred bytes.
    private static func containerIdentifier(at path: String, read: (String) async -> Data?) async -> String? {
        if let cached = identifiers[path] {
            return cached
        }
        let metadata = path + "/.com.apple.mobile_container_manager.metadata.plist"
        let identifier: String? = await {
            guard let data = await read(metadata),
                  let plist = try? PropertyListSerialization
                  .propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String, !identifier.isEmpty else { return nil }
            return identifier
        }()
        identifiers[path] = .some(identifier)
        return identifier
    }

    /// One table for many lookups: a breadcrumb asks once per crumb, and the
    /// table is a walk over every installed app.
    static func lookup(for apps: [InstalledApp]) -> (String) -> FolderDecoration? {
        let table = presentations(for: apps)
        return { table[displayPath($0)] }
    }

    private static func presentations(for apps: [InstalledApp]) -> [String: FolderDecoration] {
        var matches: [String: [(app: InstalledApp, group: String?)]] = [:]
        for app in apps {
            var containers: [(path: String, group: String?)] = [(app.bundlePath, nil)]
            let bundleContainer = URL(fileURLWithPath: displayPath(app.bundlePath)).deletingLastPathComponent()
            if bundleContainer.deletingLastPathComponent().path == bundleRoot {
                containers.append((bundleContainer.path, nil))
            }
            if let dataPath = app.dataPath {
                containers.append((dataPath, nil))
            }
            containers += app.groupPaths.map { ($0.value, $0.key) }
            for container in containers {
                matches[displayPath(container.path), default: []].append((app, container.group))
            }
        }
        return matches.mapValues { owners in
            let names = Set(owners.map(\.app.name)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let groups = Set(owners.compactMap(\.group)).sorted()
            let identifiers = Set(owners.map(\.app.bundleIdentifier))
            return FolderDecoration(
                name: (groups.isEmpty ? names : groups).joined(separator: ", "),
                detail: groups.isEmpty ? nil : names.joined(separator: ", "),
                applicationIdentifier: identifiers.count == 1 ? identifiers.first : nil
            )
        }
    }

    /// These aliases affect lookup labels only; they never decide permission or operation paths.
    static func displayPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private final class IdentifierCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String?] = [:]
        subscript(path: String) -> String?? {
            get { lock.lock(); defer { lock.unlock() }; return values[path] }
            set { lock.lock(); values[path] = newValue; lock.unlock() }
        }
    }
}
