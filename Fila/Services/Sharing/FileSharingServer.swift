import FilaLog
import FilaProtocol
import FilaRemote
import Foundation
import UIKit

extension Notification.Name {
    /// The server started, stopped, or logged a line. `FileSharingViewController`
    /// is the only listener; it is a notification rather than a callback because
    /// that is how everything else in this app announces itself, and because a
    /// screen that has gone away must not have to remember to unsubscribe.
    static let filaRemoteServerChanged = Notification.Name("wiki.qaq.fila.remote")
}

/// The WebDAV server as the app holds it: one for the process, started and
/// stopped by the user, mirrored onto the main actor so a screen can read it.
///
/// Every security decision this feature makes is visible from here. It is off
/// until someone turns it on; it will not start without a password; and it goes
/// down when the app leaves the screen unless the user has said otherwise —
/// which, being honest about it, iOS is going to enforce shortly afterwards
/// whatever the switch says.
@MainActor
final class FileSharingServer {
    static let shared = FileSharingServer()

    private(set) var status: WebDAVServer.Status = .stopped
    private(set) var log: [WebDAVServer.LogEntry] = []
    /// Set when a start failed, and cleared by the next one. A port already in
    /// use is the only way this happens in practice.
    private(set) var startFailure: String?

    private let server = WebDAVServer(service: WebDAVFileService())
    private var background: UIBackgroundTaskIdentifier = .invalid

    var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    /// `http://192.168.x.x:8080` — the string somebody types into a browser.
    var addresses: [String] {
        guard case let .running(port) = status else { return [] }
        return RemoteAddress.localAddresses().map { "http://\($0):\(port)" }
    }

    private init() {
        // `onChange` fires on the listener's queue; everything published from
        // here has to arrive on the main actor, and this is the one hop.
        server.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let notifications = NotificationCenter.default
        notifications.addObserver(
            self,
            selector: #selector(applicationWillResign),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        notifications.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - Control

    /// True from the tap until the listener is up, including the round trip
    /// that canonicalises the shared folder; the switch stays on across it.
    var isStarting: Bool {
        resolvingRoot || status == .starting
    }

    private var resolvingRoot = false

    func start() {
        let preferences = AppPreferences.shared
        startFailure = nil
        resolvingRoot = true
        refresh()
        Task {
            // The server compares canonical paths, and only the daemon can
            // resolve a folder `mobile` has no search permission into. A
            // folder that has gone is a start failure, not a share of nothing.
            let root = try? await FileSession.shared.perform(retryOnDisconnect: true) {
                try await $0.details(of: preferences.serverRoot)
            }
            resolvingRoot = false
            guard let root, root.node.kind == .directory else {
                FilaLog.warning("sharing not started: \(preferences.serverRoot) is not a directory")
                startFailure = String(
                    localized: "The shared folder is unavailable. Choose another folder and start sharing again."
                )
                refresh()
                return
            }
            start(root: root.path)
        }
    }

    private func start(root: String) {
        let preferences = AppPreferences.shared
        do {
            try server.start(.init(
                port: preferences.serverPort,
                username: preferences.serverUsername,
                password: preferences.serverPassword,
                root: root,
                // Not advertised: the browser is the client, and a Finder
                // sidebar entry only invites the WebDAV mount nobody wanted.
                advertisesBonjour: false,
                serviceName: UIDevice.current.name,
                // `WebUI/dist`, copied in by the "Build Web UI" build phase.
                webRoot: Bundle.main.url(forResource: "WebUI", withExtension: nil),
                // The page's row icons are the pictures the app draws.
                typeIcon: { name, isDirectory in
                    await MainActor.run {
                        FilePresentation.image(kind: isDirectory ? .directory : .regular, name: name)?.pngData()
                    }
                }
            ))
        } catch {
            // The listener's own failures already log themselves; this is the
            // pair the server refuses before there is one — no password, or a
            // port number that is not one.
            FilaLog.warning("sharing refused to start on port \(preferences.serverPort): \(error)")
            startFailure = String(localized: "Unable to start sharing. Check the port number and try again.")
        }
        refresh()
    }

    func stop() {
        server.stop()
        endBackgroundTask()
        refresh()
    }

    func clearLog() {
        server.clearLog()
    }

    // MARK: - Leaving the screen

    /// **iOS suspends this app a few seconds after it leaves the screen, and a
    /// suspended process does not answer a socket.** *Keep Running in
    /// Background* buys the grace period `beginBackgroundTask` grants — long
    /// enough for a transfer that was already moving to land — and nothing
    /// more. There is no background mode that would make it more than that: a
    /// file manager is not audio, not navigation and not VoIP, and claiming one
    /// of those to hold a socket open is how an app gets pulled.
    ///
    /// So the switch is honest rather than aspirational: off, the server stops
    /// the moment the app does, and the user is not left believing their laptop
    /// still has a mount.
    @objc private func applicationWillResign() {
        guard isRunning else { return }
        guard AppPreferences.shared.keepsServerRunningInBackground else {
            stop()
            return
        }
        endBackgroundTask()
        background = UIApplication.shared.beginBackgroundTask(withName: "wiki.qaq.fila.webdav") { [weak self] in
            // The grace period is over and the app is about to be suspended.
            // Stopping here rather than being frozen mid-request means the
            // client is told, instead of waiting for a timeout.
            Task { @MainActor in self?.stop() }
        }
    }

    @objc private func applicationDidBecomeActive() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func refresh() {
        status = server.status
        log = server.log.reversed()
        NotificationCenter.default.post(name: .filaRemoteServerChanged, object: nil)
    }
}
