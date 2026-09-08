import FilaLog
import FileProvider
import UIKit

/// The Files app location, "Fila". One replicated domain for the process,
/// added at launch and rebuilt when its folder changes.
///
/// The domain carries only a name. Which folder it shows is the shared
/// `ProviderLocation`; the extension reads that when the system starts it.
/// Below iOS 16 there is no replicated File Provider, and the extension's
/// `MinimumOSVersion` keeps it out of Files there rather than half in.
///
/// The system trusts its replica and asks the extension for changes only
/// when signalled; a folder on disk signals nobody. So the app signals: once
/// the domain is up, whenever it comes to the front, and after every job it
/// ran — that last one is how Fila's own edits reach Files promptly.
enum FileProviderDomain {
    @available(iOS 16.0, *)
    private static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("wiki.qaq.fila.documents"), displayName: "Fila")
    }

    private static var observers: [NSObjectProtocol] = []

    static func register() {
        guard #available(iOS 16.0, *) else { return }
        NSFileProviderManager.add(domain) { error in
            if let error {
                FilaLog.error("Files domain registration failed: \(error)")
            }
            signalChanges()
        }
        guard observers.isEmpty else { return }
        for name in [UIApplication.didBecomeActiveNotification, .filaJobFinished] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                signalChanges()
            })
        }
    }

    /// Ask the system to enumerate what changed.
    static func signalChanges() {
        guard #available(iOS 16.0, *), let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { error in
            if let error {
                FilaLog.error("Files working set signal failed: \(error)")
            }
        }
    }

    /// The folder changed, so the replica of the old one is meaningless: the
    /// domain is removed and added again. iOS offers only the mode that drops
    /// unsynced edits with it; the settings page says so before the change.
    static func reset() {
        guard #available(iOS 16.0, *) else { return }
        NSFileProviderManager.remove(domain, mode: .removeAll) { _, error in
            if let error {
                FilaLog.error("Files domain removal failed: \(error)")
            }
            register()
        }
    }
}
