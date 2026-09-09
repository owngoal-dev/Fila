import FilaBackendKit
import FilaLog
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

    static func bootstrap() {
        FilaLog.start(.app)
        FilaLog.minimumLevel = LogPreferences.level
        let host = AppBackendHost()
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
    func log(_ message: String) {
        FilaLog.info(message)
    }

    func warn(_ message: String) {
        FilaLog.warning(message)
    }
}
