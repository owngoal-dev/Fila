import FilaCore
import SnapKit
import Then
import UIKit

/// Installed apps, and the jump into their containers.
///
/// The jailbreak-specific reason to open a file manager: an app's Data
/// container is a UUID under `/var/mobile/Containers/Data/Application` and
/// nothing on the filesystem says which one. See `ApplicationCatalog` for
/// where the answer comes from, and what is missing when it cannot.
final class ApplicationListViewController: BackendListViewController<InstalledApp>, TabContentDecorationSource {
    private let backend: ApplicationBackend
    private var filter = ""
    private let cell = UICollectionView.CellRegistration<BackendRowCell, InstalledApp> { cell, _, app in
        cell.configure(name: app.name, detail: app.bundleIdentifier, image: UIImage(systemName: "app"))
        cell.showApplicationIcon(app.bundleIdentifier, artwork: ApplicationArtworkCache.shared)
    }

    private var bundle: Bundle { ApplicationBackend.bundle }

    init(backend: ApplicationBackend) {
        self.backend = backend
        super.init()
        title = String(localized: "Applications", bundle: bundle)
        // Sort and scope are this screen's actions, trailing in the bar.
        trailingNavigationItems = [arrangementItem]
    }

    // MARK: - Decoration

    /// The catalogue as a crumb: its sidebar picture and its name. Its
    /// detail screens draw it first and pop back here from it.
    var rootCrumb: PathBarView.Crumb {
        PathBarView.Crumb(
            title: title ?? String(localized: "Applications", bundle: bundle),
            target: backend.id.rawValue,
            icon: BackendScreens.shell?.rootArtwork(for: backend.root)
        )
    }

    func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        [rootCrumb]
    }

    /// One crumb, the screen itself: nothing before it to select.
    func tabContent(_: TabContentViewController, didSelectDecorationCrumb _: PathBarView.Crumb) {}

    /// The menu that orders and narrows the list: by name or identifier, all
    /// apps or only the user's or the system's.
    private lazy var arrangementItem = UIBarButtonItem(
        image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
        menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.arrangementElements() ?? []) },
        ])
    ).then {
        $0.accessibilityLabel = String(localized: "Sort and Filter", bundle: bundle)
        if #available(iOS 26.0, *) {
            $0.identifier = "arrangement"
            $0.sharesBackground = false
        }
    }

    private func arrangementElements() -> [UIMenuElement] {
        let sorts = AppSort.allCases.map { sort in
            UIAction(title: title(of: sort), state: backend.sort == sort ? .on : .off) { [weak self] _ in
                self?.backend.sort = sort
                self?.rearrange(animated: true)
            }
        }
        let scopes = AppScope.allCases.map { scope in
            UIAction(
                title: title(of: scope),
                image: UIImage(systemName: scope == .all ? "square.grid.2x2" : scope == .user ? "person" : "gearshape"),
                state: backend.scope == scope ? .on : .off
            ) { [weak self] _ in
                self?.backend.scope = scope
                self?.rearrange(animated: true)
            }
        }
        return [
            UIMenu(title: String(localized: "Sort By", bundle: bundle), options: .displayInline, children: sorts),
            UIMenu(
                title: String(localized: "Applications", bundle: bundle),
                options: [.displayInline, .singleSelection],
                children: scopes
            ),
        ]
    }

    private func title(of sort: AppSort) -> String {
        switch sort {
        case .name: String(localized: "Name", bundle: bundle)
        case .identifier: String(localized: "Bundle Identifier", bundle: bundle)
        }
    }

    private func title(of scope: AppScope) -> String {
        switch scope {
        case .all: String(localized: "All Apps", bundle: bundle)
        case .user: String(localized: "User Apps", bundle: bundle)
        case .system: String(localized: "System Apps", bundle: bundle)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        definesPresentationContext = true

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        installSearch(search)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.backend.catalogChanged() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            navigationItem.searchController?.isActive = false
        }
    }

    // MARK: - List hooks

    override func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: InstalledApp) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
    }

    /// The database read always finishes — an unanswerable
    /// `LSApplicationWorkspace` falls back to a scan, and a scan that finds
    /// nothing returns nothing — so this always ends in rows or in a stated
    /// reason there are none.
    override func load() -> AsyncThrowingStream<[InstalledApp], Error> {
        let backend = backend
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(await backend.applications())
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func changes() async throws -> AsyncThrowingStream<Void, Error>? {
        let hints = backend.changes()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in hints { continuation.yield(()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func arrange(_ items: [InstalledApp]) -> [InstalledApp] {
        let needle = filter.lowercased()
        let matching = items.filter { app in
            backend.scope.includes(app)
                && (needle.isEmpty
                    || app.name.lowercased().contains(needle)
                    || app.bundleIdentifier.lowercased().contains(needle))
        }
        switch backend.sort {
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .identifier:
            return matching.sorted {
                $0.bundleIdentifier.localizedStandardCompare($1.bundleIdentifier) == .orderedAscending
            }
        }
    }

    override var statusContent: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        if isLoading, items.isEmpty {
            return .loading(String(localized: "Loading Installed Apps…", bundle: bundle))
        }
        guard items.isEmpty else {
            return .message(
                symbol: "magnifyingglass",
                title: String(localized: "No Matches", bundle: bundle),
                detail: filter.isEmpty
                    ? String(localized: "No apps match this filter. Choose All Apps, User Apps, or System Apps.", bundle: bundle)
                    : String(localized: "No apps match “\(filter)”. Try a different search.", bundle: bundle)
            )
        }
        // Reachable through a link after the sidebar row is gone: say why
        // rather than claiming the database would not answer.
        if !backend.isEnabled {
            return .message(
                symbol: "questionmark.app.dashed",
                title: String(localized: "Applications Unavailable", bundle: bundle),
                detail: String(localized: "Fila cannot see other apps on this device.", bundle: bundle)
            )
        }
        // Both sources came back empty: the installation database would not
        // answer *and* nothing was under the bundle container root. Saying so
        // is the only way the difference from "you have no apps" is visible.
        return .message(
            symbol: "questionmark.app.dashed",
            title: String(localized: "Unable to List Apps", bundle: bundle),
            detail: String(localized: "Fila could not read the list of installed apps. Pull down to refresh.", bundle: bundle)
        )
    }
}

extension ApplicationListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text ?? ""
        rearrange(animated: false)
    }
}

extension ApplicationListViewController: UICollectionViewDelegate {
    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let app = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let locations = app.locations.map { location in
                UIAction(
                    title: ApplicationDetailViewController.title(of: location),
                    image: UIImage(systemName: ApplicationDetailViewController.symbol(of: location))
                ) { [weak self] _ in
                    guard let self, let navigation = navigationController,
                          navigation.topViewController === self,
                          let browser = browser(for: location.path) else { return }
                    // Detail first, unanimated, so Back from the browser lands
                    // where a tap would have: detail, then this list.
                    navigation.pushViewController(
                        ApplicationDetailViewController(app: app, backend: backend, root: rootCrumb), animated: false
                    )
                    navigation.pushViewController(browser, animated: true)
                }
            }
            let copy = UIAction(
                title: String(localized: "Copy Bundle Identifier", bundle: self?.bundle ?? .main),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = app.bundleIdentifier
            }
            return UIMenu(title: app.name, children: [
                UIMenu(options: .displayInline, children: locations),
                UIMenu(options: .displayInline, children: [copy]),
            ])
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let app = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(
            ApplicationDetailViewController(app: app, backend: backend, root: rootCrumb), animated: true
        )
    }

    /// A browser at a local path, from the shell.
    func browser(for path: String) -> UIViewController? {
        guard let location = backend.local.servicePath(forAbsolute: path) else { return nil }
        return BackendScreens.shell?.browser(for: BackendLocation(backend: backend.local.id, item: location.description))
    }
}
