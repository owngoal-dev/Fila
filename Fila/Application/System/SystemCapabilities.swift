import FilaBackendKit
import FilaBackendUI
import Foundation

/// Features that need more than the app's own sandbox, and the one place that
/// says whether each is available.
///
/// Available means the environment permits it **and** the user has not turned
/// it off. The environment side is the live handshake — `Hello.backend`, the
/// only honest answer to what this process can reach — never a build flag or
/// the construction-time `daemonIsInstalled`. The user side is the owning
/// backend's preference.
///
/// Everything that offers a feature asks here and offers nothing when the
/// answer is no: the sidebar drops the row, the menu drops the submenu, the
/// `.app` folder keeps its real name.
@MainActor
enum SystemCapabilities {
    /// The applications module's capability, or nil in a build that does not
    /// bundle it or where its bootstrap failed. Every app-shaped question the
    /// shell has goes through here.
    static var applications: (any ApplicationCapability)? {
        BackendComposition.registry.provider((any ApplicationCapability).self)
    }

    /// The artwork renderer the applications module provides, for rows that
    /// show an app. Nil wherever `applications` is nil.
    static var applicationArtwork: (any ApplicationArtwork)? {
        BackendComposition.registry.provider((any ApplicationArtwork).self)
    }

    /// The Applications page, and the app names and icons on `.app` folders
    /// and containers. The module answers from its own switch and the
    /// handshake; absent module, absent feature.
    static var showsApplications: Bool {
        applications?.isEnabled ?? false
    }

    /// The Run submenu. Only `filad` can open a terminal —
    /// `TerminalAccess.openTerminal` refuses without it — so this is exactly
    /// `isPrivileged`, and nothing until the handshake has landed.
    static var runsPrograms: Bool {
        FileSession.shared.hello?.isPrivileged == true
    }
}
