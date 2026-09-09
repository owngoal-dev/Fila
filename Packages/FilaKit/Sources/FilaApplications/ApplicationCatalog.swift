import FilaBackendKit
import FilaLog
import FilaProtocol
import Foundation
import ObjectiveC

/// Installed apps, and the jump to their Bundle and Data containers.
///
/// This is the jailbreak-specific reason people open a file manager at all, and
/// there is no public API for it. `LSApplicationWorkspace` is the one the system
/// itself uses; the app is unsandboxed, so it answers. When that API is absent,
/// the containers can still be listed through the local file contract, which
/// gives the bundles but not the data containers, because the mapping between
/// the two lives only in that database.
@objc private protocol ApplicationOpening {
    func openApplicationWithBundleID(_ identifier: String) -> Bool
}

public enum ApplicationCatalog {
    /// LaunchServices opens the registered app as the current user; no helper
    /// process or privileged daemon request is involved.
    @MainActor
    public static func open(_ app: InstalledApp) -> Bool {
        guard let workspace = defaultWorkspace(),
              workspace.responds(to: #selector(ApplicationOpening.openApplicationWithBundleID(_:)))
        else { return false }
        return unsafeBitCast(workspace, to: ApplicationOpening.self).openApplicationWithBundleID(app.bundleIdentifier)
    }

    /// LaunchServices first; a scan of the bundle container root through
    /// `files` when it answers nothing. Both sorted by name.
    public static func load(files: any FileService) async -> [InstalledApp] {
        let apps = workspaceApplications()
        if !apps.isEmpty {
            FilaLog.info("\(apps.count) app(s) from LaunchServices")
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // The fallback, and the line that says the fast path answered nothing —
        // which on a locked-down OS is what "Installed Apps is empty" means.
        let scanned = await scanBundleContainers(files: files)
        FilaLog.info("LaunchServices answered nothing; \(scanned.count) app(s) from a container scan")
        return scanned.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The one place the private class is resolved: absent, or not answering
    /// `defaultWorkspace`, is the same "no LaunchServices here" for both callers.
    private static func defaultWorkspace() -> NSObject? {
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("defaultWorkspace"))
        else { return nil }
        return type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
    }

    private static func workspaceApplications() -> [InstalledApp] {
        guard let workspace = defaultWorkspace(),
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
        let bundle = ApplicationBackend.bundle
        let candidates: [(String, String?)] = [
            (String(localized: "Version", bundle: bundle), string("shortVersionString")),
            (String(localized: "Build", bundle: bundle), string("bundleVersion")),
            (String(localized: "Type", bundle: bundle), string("applicationType")),
            (String(localized: "Team ID", bundle: bundle), string("teamID")),
            (String(localized: "Signer", bundle: bundle), string("signerIdentity")),
            (String(localized: "Installed", bundle: bundle), (value("registeredDate") as? Date).map {
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

    static let bundleRoot = "/var/containers/Bundle/Application"

    /// The fallback: every `.app` under the bundle container root, named by its
    /// directory. No data containers — nothing on disk links a bundle UUID to
    /// its data UUID without reading the installation database.
    static func scanBundleContainers(files: any FileService) async -> [InstalledApp] {
        guard let root = try? ServicePath(bundleRoot),
              let containers = try? await files.entries(in: root) else { return [] }
        var apps: [InstalledApp] = []
        for container in containers where container.entersDirectory {
            guard let path = try? root.appending(container.name),
                  let contents = try? await files.entries(in: path) else { continue }
            guard let bundle = contents.first(where: { $0.name.hasSuffix(".app") }) else { continue }
            let name = (bundle.name as NSString).deletingPathExtension
            apps.append(InstalledApp(
                name: name,
                bundleIdentifier: container.name,
                bundlePath: bundleRoot + "/" + container.name + "/" + bundle.name,
                dataPath: nil
            ))
        }
        return apps
    }
}

extension FileService {
    /// A complete listing, or a failure: a scan that read only part of a
    /// directory must not be presented as the whole of it.
    func entries(in directory: ServicePath, limit: Int = 50_000) async throws -> [FileEntry] {
        var entries: [FileEntry] = []
        for try await batch in try await list(directory) {
            guard batch.count <= limit - entries.count else { throw FilaFailure(errno: E2BIG, path: directory.description) }
            entries.append(contentsOf: batch)
        }
        return entries
    }
}
