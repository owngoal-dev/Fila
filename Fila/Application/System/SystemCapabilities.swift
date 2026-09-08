import Foundation

/// Features that need more than the app's own sandbox, and the one place that
/// says whether each is available.
///
/// Available means the environment permits it **and** the user has not turned
/// it off. The environment side is the live handshake — `Hello.backend`, the
/// only honest answer to what this process can reach — never a build flag or
/// the construction-time `daemonIsInstalled`. The user side is `AppPreferences`.
///
/// Everything that offers a feature asks here and offers nothing when the
/// answer is no: the sidebar drops the row, the menu drops the submenu, the
/// `.app` folder keeps its real name. A feature that is on and then fails at
/// the system call still falls back on its own — see `InstalledAppCatalog.load`.
@MainActor
enum SystemCapabilities {
    /// The Applications page, and the app names and icons on `.app` folders
    /// and containers. `LSApplicationWorkspace` and the bundle-container scan
    /// both read outside this app's container, so a sandboxed local backend
    /// can only ever answer with nothing. Wait for the handshake before
    /// allowing private framework calls in an unknown environment.
    static var showsApplications: Bool {
        guard AppPreferences.shared.showsApplications,
              let backend = FileSession.shared.hello?.backend else { return false }
        if case .local(.container) = backend {
            return false
        }
        return true
    }

    /// The Run submenu. Only `filad` can open a terminal —
    /// `DaemonLink.openTerminal` refuses without it — so this is exactly
    /// `isPrivileged`, and nothing until the handshake has landed.
    static var runsPrograms: Bool {
        AppPreferences.shared.runsPrograms && FileSession.shared.hello?.isPrivileged == true
    }
}
