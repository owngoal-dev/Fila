import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootSplitViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        // A `fila://` link that launched the app arrives here, and one handed
        // to an app that is already running arrives below. Both, always: a
        // scheme wired to only the warm path fails exactly when someone taps
        // the link with the app not running, which is most of the time.
        root.follow(connectionOptions.urlContexts)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-FilaSidebarRegression") {
            SidebarNavigationProbe.run(in: root)
        }
        #endif
    }

    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        shell?.follow(contexts)
    }

    /// The tab's stack is written down on every push and pop; its scroll
    /// position is not, because that would be a write per pixel. This is where
    /// it gets caught — and it is the last moment before the app can be killed
    /// without warning.
    func sceneDidEnterBackground(_: UIScene) {
        shell?.rememberState()
    }

    private var shell: RootSplitViewController? {
        window?.rootViewController as? RootSplitViewController
    }
}
