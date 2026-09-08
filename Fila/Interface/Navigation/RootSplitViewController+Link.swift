import AlertController
import FilaProtocol
import UIKit

/// Where a `fila://` link ends up.
///
/// The parser (`FilaLink`) decides what a URL means and this decides what to
/// show for it — one exhaustive switch, so a verb added to the enum cannot be
/// quietly forgotten here. Every branch navigates, reveals or inspects; there
/// is nothing to confirm because there is nothing destructive to confirm.
extension RootSplitViewController {
    /// Every URL a scene hands us — a cold launch through
    /// `connectionOptions.urlContexts`, a warm one through
    /// `scene(_:openURLContexts:)`.
    func follow(_ contexts: Set<UIOpenURLContext>) {
        // A `file:` URL is not a link: it is a file the system already copied
        // into this app's Inbox for *Copy to Fila*. One panel for the whole
        // batch, and never through `FilaLink` — see `importFiles`.
        let files = contexts.map(\.url).filter(\.isFileURL)
        if !files.isEmpty { importFiles(files) }
        for context in contexts where !context.url.isFileURL { follow(context.url) }
    }

    func follow(_ url: URL) {
        // Deferred a turn rather than acted on inline: on a cold launch this is
        // called while the scene is still connecting, and the split view has
        // not finished laying itself out — a push or a present from inside that
        // window either animates from nowhere or is dropped.
        Task { @MainActor in
            guard let link = FilaLink(url) else {
                self.reportUnrecognized(url)
                return
            }
            await FileSession.shared.ready()
            self.follow(link)
        }
    }

    /// Not private, and only for one caller inside the app: *Show Original* on
    /// a symlink wants exactly what `fila://reveal` and `fila://open` already
    /// do — a directory is opened, a file is revealed with its row selected —
    /// and a second copy of that would be a second place for the two to drift
    /// apart. Everything else still arrives as a URL.
    func follow(_ link: FilaLink) {
        switch link {
        case let .directory(path):
            open(path)
        case let .newTab(path):
            // A `tab` flag on `open` rather than a `tab` verb: a tab is one
            // place the app can be, so `open` with `tab=new` is `open` plus one
            // bit — a separate verb would spell the same destination twice.
            //
            // Capped, and the cap drops the *new* tab rather than an old one:
            // this list is on the other side of an unauthenticated entry point,
            // so a page that keeps sending links must not be able to grow a
            // preference without bound — nor to push a person's own tabs out of
            // the switcher. `BrowserTabStore.limit` is the number, and
            // `BrowserTabStore.openFromLink` is where it is enforced.
            openFromLink(path)
        case let .reveal(path):
            // The folder the item is in, and the row itself once the page
            // carrying it arrives — the listing streams, so the row does not
            // exist yet at this point and may never exist at all.
            open(parent(of: path), select: (path as NSString).lastPathComponent)
        case let .view(path):
            // These three wait on the daemon rather than failing while it is
            // still coming up. `filad` is on-demand and a link can easily
            // arrive during the second the app spends saying *Connecting…*;
            // dropping the destination there would look like the scheme not
            // working. `FileSession.perform` awaits the handshake itself, so
            // this is simply a request that takes a moment.
            Task { await self.openFile(at: path, session: FileSession.shared) }
        case let .info(path):
            showProperties(of: path)
        case let .search(query, root):
            search(query, in: root)
        case let .app(bundle, container):
            openApp(bundle: bundle, container: container)
        case .installedApps:
            push(AppListViewController())
        case .settings:
            presentSettings()
        }
    }

    /// A path's directory. `deletingLastPathComponent` on `/etc` gives `/`,
    /// which is right, and on `/` gives `/`, which is also right — revealing
    /// the volume root shows the volume root.
    private func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func showProperties(of path: String) {
        Task {
            let session = FileSession.shared
            do {
                let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
                self.presentAsSheet(
                    UINavigationController(rootViewController: PropertiesViewController(
                        details: details,
                        link: session.link
                    ))
                )
            } catch let failure as FilaFailure {
                self.report(failure)
            } catch {}
        }
    }

    private func search(_ query: String, in root: String) {
        push(SearchViewController(root: root, query: query))
    }

    private func openApp(bundle: String, container: FilaLink.AppContainer) {
        Task {
            // Waits on the daemon for the same reason the file verbs do: the
            // fallback source lists containers through it, so asking before the
            // handshake lands would answer "not installed" for an app that is.
            await FileSession.shared.ready()
            guard SystemCapabilities.showsApplications else {
                self.alert(
                    title: String(localized: "Applications Unavailable"),
                    message: String(localized: "Turn on Show Applications in Settings. If it is already on, Fila cannot see other apps on this device.")
                )
                return
            }
            let apps = await InstalledAppCatalog.load(session: FileSession.shared)
            let match = apps.first { $0.bundleIdentifier.caseInsensitiveCompare(bundle) == .orderedSame }
            guard let app = match else {
                self.alert(
                    title: String(localized: "App Not Found"),
                    message: String(localized: "“\(bundle)” is not installed on this device.")
                )
                return
            }
            switch container {
            case .bundle:
                self.open(app.bundlePath)
            case .data:
                // Absent whenever the installation database could not be read —
                // see `InstalledAppCatalog`. Saying so beats silently showing the
                // bundle instead and letting the user work out why.
                guard let data = app.dataPath else {
                    self.alert(
                        title: String(localized: "No App Data"),
                        message: String(localized: "Fila could not find App Data for \(app.name).")
                    )
                    return
                }
                self.open(data)
            }
        }
    }

    /// A scheme that silently does nothing is indistinguishable from a broken
    /// app, so an unrecognised link says so — and says so as a sentence, never
    /// as a crash. The URL is echoed back truncated: it came from a stranger
    /// and an alert is not a place to render an arbitrary kilobyte.
    private func reportUnrecognized(_ url: URL) {
        alert(
            title: String(localized: "Unsupported Link"),
            message: String(localized: "Fila cannot open this link. Check the address and try again.")
                + "\n\n" + String(url.absoluteString.prefix(200))
        )
    }

    private func alert(title: String, message: String) {
        let alert = AlertViewController(title: title, message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }
}
