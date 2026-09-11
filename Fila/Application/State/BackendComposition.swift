import FilaBackendKit
import FilaLog
import FilaFileOps
import Foundation

/// The app's composition root for backends.
///
/// Runs in `main` before `UIApplicationMain`: by then dyld has mapped every
/// module framework the app links, and nothing has yet asked for a backend.
/// The registry it produces is the only place the shell learns which backends
/// exist; there is no concrete module type named anywhere in `Fila/`.
@MainActor
enum BackendComposition {
    private(set) static var registry = BackendRegistry()

    /// Every backend the app composes over: the session's local backend
    /// first — the registry's, or the in-process fallback when no local
    /// module bootstrapped — then the rest of the registry.
    static var backends: [any Backend] {
        let local = FileSession.shared.local
        return [local] + registry.backends.filter { $0 !== local }
    }

    static var fileBackends: [any FileBackend] {
        backends.compactMap { $0 as? any FileBackend }
    }

    /// The merged sidebar over every backend. Built when a window's shell
    /// loads, which is after bootstrap: nothing asks for a sidebar before.
    static let sidebar = SidebarModel(backends: backends, registry: registry)

    /// What modules get from the app; also what the fallback backend gets.
    static let host = AppBackendHost()

    static func bootstrap() {
        FilaLog.start(.app)
        FilaLog.minimumLevel = LogPreferences.level
        guard let version = BackendHostVersion(bundle: .main) else {
            FilaLog.error("backend discovery skipped: the app bundle carries no version")
            return
        }
        registry = BackendModuleDiscovery.bootstrap(
            BackendModuleDiscovery.embeddedCandidates(),
            hostVersion: version,
            host: host
        )
        FilaLog.info(
            "backend modules: \(registry.modules.map(\.bundleIdentifier).joined(separator: ", "))"
        )
    }
}

/// What modules get from the app. Bootstrap diagnostics land in the log ring
/// and nowhere else: a module that could not start is invisible in the UI.
@MainActor
final class AppBackendHost: BackendHost {
    let defaults = UserDefaults.standard
    let credentials: any CredentialStore = KeychainCredentialStore()

    func log(_ message: String) {
        FilaLog.info(message)
    }

    func warn(_ message: String) {
        FilaLog.warning(message)
    }

    /// A backend saved after bootstrap. The registry publishes the change
    /// and the sidebar model subscribes to the newcomer from there.
    func addBackend(_ backend: any Backend, screen: @escaping @MainActor (BackendLocation) -> AnyObject?) throws {
        try BackendComposition.registry.add(backend, screen: screen)
        FilaLog.info("backend added: \(backend.id)")
    }

    func removeBackend(_ id: BackendID) {
        BackendComposition.registry.remove(id)
        FilaLog.info("backend removed: \(id)")
    }

    /// Save to Fila's shared Inbox. Open In imports retain the system's
    /// Documents/Inbox until the user chooses a destination. Without a
    /// provisioned App Group, the app still exposes that local Inbox.
    var inboxDirectory: String? {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier),
           let inbox = try? SharedInbox.directory(in: group) {
            return inbox.path
        }
        let inbox = NSHomeDirectory() + "/Documents/Inbox"
        try? FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        return inbox
    }
}
