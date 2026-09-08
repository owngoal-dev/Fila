import FilaProtocol
import Foundation
import ObjectiveC

struct InstalledApp: Hashable {
    var name: String
    var bundleIdentifier: String
    var bundlePath: String
    /// Nil when the app has no data container of its own, and also when the
    /// fallback source found it — see `scanBundleContainers`.
    var dataPath: String?
    /// The installation database owns group identifiers and their container URLs.
    var groupPaths: [String: String] = [:]
    /// Facts the installation database states about the app, in display
    /// order, as localized label and value. Empty for the fallback scan.
    var details: [Detail] = []

    struct Detail: Hashable {
        var label: String
        var value: String
    }

    /// The first candidate name with a visible character; failing all, the
    /// last component of the identifier, so `com.apple.MediaRemoteUI` reads as
    /// `MediaRemoteUI`. LaunchServices hands back a lone U+200E for some
    /// system apps, which is why format characters count as empty here.
    static func name(_ candidates: String?..., identifier: String) -> String {
        let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        for candidate in candidates {
            let name = candidate?.trimmingCharacters(in: blank) ?? ""
            if !name.isEmpty {
                return name
            }
        }
        return String(identifier.split(separator: ".").last ?? Substring(identifier))
    }
}

/// Installed apps, and the jump to their Bundle and Data containers.
///
/// This is the jailbreak-specific reason people open a file manager at all, and
/// there is no public API for it. `LSApplicationWorkspace` is the one the system
/// itself uses; the app is unsandboxed, so it answers. When that API is absent,
/// the containers can still be listed through the daemon, which
/// gives the bundles but not the data containers, because the mapping between
/// the two lives only in that database.
@objc private protocol ApplicationOpening {
    func openApplicationWithBundleID(_ identifier: String) -> Bool
}

enum InstalledAppCatalog {
    /// LaunchServices opens the registered app as the current user; no helper
    /// process or privileged daemon request is involved.
    @MainActor
    static func open(_ app: InstalledApp) -> Bool {
        guard SystemCapabilities.showsApplications,
              let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("defaultWorkspace")),
              let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?
              .takeUnretainedValue() as? NSObject,
              workspace.responds(to: #selector(ApplicationOpening.openApplicationWithBundleID(_:)))
        else { return false }
        return unsafeBitCast(workspace, to: ApplicationOpening.self).openApplicationWithBundleID(app.bundleIdentifier)
    }

    @MainActor
    static func load(session: FileSession) async -> [InstalledApp] {
        // Off means no LaunchServices call and no scan, for every caller —
        // the page, the folder names, the recents, the links.
        guard SystemCapabilities.showsApplications else { return [] }
        let apps = workspaceApplications()
        if !apps.isEmpty {
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let scanned = await scanBundleContainers(session: session)
        return scanned.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func workspaceApplications() -> [InstalledApp] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace"),
              let workspace = (workspaceClass as AnyObject)
              .perform(Selector(("defaultWorkspace")))?.takeUnretainedValue(),
              let proxies = workspace
              .perform(Selector(("allInstalledApplications")))?.takeUnretainedValue() as? [NSObject]
        else { return [] }

        return proxies.compactMap { proxy in
            guard let bundleURL = proxy.value(forKey: "bundleURL") as? URL else { return nil }
            let identifier = proxy.value(forKey: "applicationIdentifier") as? String
                ?? proxy.value(forKey: "bundleIdentifier") as? String
                ?? bundleURL.lastPathComponent
            return InstalledApp(
                name: InstalledApp.name(
                    proxy.value(forKey: "localizedName") as? String,
                    proxy.value(forKey: "localizedShortName") as? String,
                    identifier: identifier
                ),
                bundleIdentifier: identifier,
                bundlePath: bundleURL.path,
                dataPath: (proxy.value(forKey: "dataContainerURL") as? URL)?.path,
                groupPaths: groupPaths(for: proxy),
                details: details(for: proxy)
            )
        }
    }

    /// `LSApplicationProxy` getters, each guarded by `responds(to:)` because an
    /// unknown KVC key raises rather than returning nil. Any that this
    /// LaunchServices lacks is simply not a row.
    private static func details(for proxy: NSObject) -> [InstalledApp.Detail] {
        func value(_ key: String) -> Any? {
            proxy.responds(to: NSSelectorFromString(key)) ? proxy.value(forKey: key) : nil
        }
        func string(_ key: String) -> String? {
            let text = (value(key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        let candidates: [(String, String?)] = [
            (String(localized: "Version"), string("shortVersionString")),
            (String(localized: "Build"), string("bundleVersion")),
            (String(localized: "Type"), string("applicationType")),
            (String(localized: "Team ID"), string("teamID")),
            (String(localized: "Signer"), string("signerIdentity")),
            (String(localized: "Installed"), (value("registeredDate") as? Date).map {
                $0.formatted(date: .abbreviated, time: .shortened)
            }),
        ]
        return candidates.compactMap { label, value in value.map { InstalledApp.Detail(label: label, value: $0) } }
    }

    private static func groupPaths(for proxy: NSObject) -> [String: String] {
        let selector = NSSelectorFromString("groupContainerURLs")
        guard proxy.responds(to: selector),
              let groups = proxy.perform(selector)?.takeUnretainedValue() as? [String: URL] else { return [:] }
        return groups.reduce(into: [:]) { paths, group in
            guard !group.key.isEmpty, group.value.isFileURL else { return }
            paths[group.key] = group.value.path
        }
    }

    /// The fallback: every `.app` under the bundle container root, named by its
    /// directory. No data containers — nothing on disk links a bundle UUID to
    /// its data UUID without reading the installation database.
    @MainActor
    private static func scanBundleContainers(session: FileSession) async -> [InstalledApp] {
        let root = "/var/containers/Bundle/Application"
        guard let containers = try? await DirectoryReader.entries(in: root, session: session) else { return [] }
        var apps: [InstalledApp] = []
        for container in containers where container.isNavigable {
            let containerPath = root + "/" + container.name
            guard let contents = try? await DirectoryReader.entries(in: containerPath, session: session) else {
                continue
            }
            guard let bundle = contents.first(where: { $0.name.hasSuffix(".app") }) else { continue }
            let name = (bundle.name as NSString).deletingPathExtension
            apps.append(InstalledApp(
                name: name,
                bundleIdentifier: container.name,
                bundlePath: containerPath + "/" + bundle.name,
                dataPath: nil
            ))
        }
        return apps
    }
}
