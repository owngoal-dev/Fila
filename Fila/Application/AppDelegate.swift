import AlertController
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
        FilaLog.start(.app)
        FilaLog.minimumLevel = LogPreferences.level
        do { try TerminalTemporaryFiles.cleanup() }
        catch { FilaLog.error("Terminal configuration cleanup failed: \(error)") }
        AlertControllerConfiguration.accentColor = UIColor(named: "AccentColor") ?? .systemBlue
        // The app icon, light and dark, rendered by Scripts/make-app-mark.swift.
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        let info = Bundle.main.infoDictionary
        FilaLog.info(
            "Fila \(info?["CFBundleShortVersionString"] as? String ?? "?")"
                + " (\(info?["CFBundleVersion"] as? String ?? "?"))"
                + " on \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        do { try FileProviderSettingsViewController.initializeDefault() }
        catch { FilaLog.error("File Provider default location initialization failed: \(error)") }
        FileProviderDomain.register()
        Task {
            do { try await FileSession.shared.prepareTemporaryFiles() }
            catch { FilaLog.error("Temporary workspace preparation failed: \(error)") }
        }

        #if DEBUG
            // The `fila://` parser is the one piece of this app that takes
            // input from a stranger, and it is pure logic over a `URL`. The
            // app target has no test target, so its check runs here — every
            // Debug launch, on the simulator and vphone.
            FilaLink.runSelfCheck()
            // Shortcuts is the second entry point that takes input from outside
            // the app, and `IntentSupport` is where that input is bounded.
            IntentSupport.runSelfCheck()
            // Same reason: the tab list is arithmetic over a plist — which tab
            // is current after a close, what the cap does, what a reload gets
            // back — and it is reachable from `fila://` too.
            BrowserTabStore.runSelfCheck()
            SearchViewController.runSelfCheck()
            PropertyListValue.runSelfCheck()
            AppFolderDisplay.runSelfCheck()
            TabContainerViewController.runSelfCheck()
        #endif
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

    func applicationWillTerminate(_: UIApplication) {
        do { try TerminalTemporaryFiles.cleanup() }
        catch { FilaLog.error("Terminal configuration cleanup failed: \(error)") }
        FileSession.shared.cleanupTemporaryFiles()
        FileSession.shared.link.invalidate()
    }
}
