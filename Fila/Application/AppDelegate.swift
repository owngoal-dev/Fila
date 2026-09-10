import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaLog
import FilaTerminal
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // First thing, so the launch itself is the log's first line. The level
        // is whatever the log screen was last set to; verbose does not survive
        // a relaunch, which is the right default for something that writes a
        // line per XPC call.
        do { try TerminalTemporaryFiles.cleanup() }
        catch { FilaLog.error("Terminal configuration cleanup failed: \(error)") }
        AlertControllerConfiguration.accentColor = UIColor(named: "AccentColor") ?? .systemBlue
        // The app icon, light and dark, rendered by Scripts/make-app-mark.swift.
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // Module screens borrow the app's browsers, pickers and feedback from
        // here; assigned before any scene can make one.
        BackendScreens.shell = AppBackendShell()
        let info = Bundle.main.infoDictionary
        FilaLog.info(
            "Fila \(info?["CFBundleShortVersionString"] as? String ?? "?")"
                + " (\(info?["CFBundleVersion"] as? String ?? "?"))"
                + " on \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        Task {
            do { try await FileSession.shared.prepareTemporaryFiles() }
            catch { FilaLog.error("Temporary workspace preparation failed: \(error)") }
        }

        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting session: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// A window closed in the app switcher, or one iOS gave up restoring:
    /// its tabs go with it. The one place a window's list is dropped on
    /// purpose — see `BrowserTabStore.forget`.
    func application(_: UIApplication, didDiscardSceneSessions sessions: Set<UISceneSession>) {
        FilaLog.info("\(sessions.count) scene session(s) discarded")
        BrowserTabStore.forget(sessions.map(\.persistentIdentifier))
    }

    /// A listing of a directory with a hundred thousand entries is the app's
    /// largest allocation by a wide margin, and jetsam gives no other notice.
    /// A screen that went blank right after one of these lines is explained.
    func applicationDidReceiveMemoryWarning(_: UIApplication) {
        FilaLog.warning("memory warning")
    }

    /// No directory polling while nothing is on screen; coming back hints
    /// every open browser once, because anything may have happened.
    func applicationDidEnterBackground(_: UIApplication) {
        for backend in BackendComposition.fileBackends {
            backend.setObservationPaused(true)
        }
    }

    func applicationWillEnterForeground(_: UIApplication) {
        for backend in BackendComposition.fileBackends {
            backend.setObservationPaused(false)
        }
    }

    func applicationWillTerminate(_: UIApplication) {
        FilaLog.info("terminating")
        do { try TerminalTemporaryFiles.cleanup() }
        catch { FilaLog.error("Terminal configuration cleanup failed: \(error)") }
        FileSession.shared.cleanupTemporaryFiles()
        FileSession.shared.link.invalidate()
    }
}
