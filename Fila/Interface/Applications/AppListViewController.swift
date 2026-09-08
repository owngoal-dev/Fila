import SnapKit
import Then
import UIKit

/// Installed apps, and the jump into their containers.
///
/// The jailbreak-specific reason to open a file manager: an app's Data container
/// is a UUID under `/var/mobile/Containers/Data/Application` and nothing on the
/// filesystem says which one. See `InstalledAppCatalog` for where the answer comes
/// from, and what is missing when it cannot.
final class AppListViewController: UIViewController {
    private let session = FileSession.shared
    private var apps: [InstalledApp] = []
    private var filter = ""
    /// The database read is in flight. It always finishes — an unanswerable
    /// `LSApplicationWorkspace` falls back to a scan, and a scan that finds
    /// nothing returns nothing — so this always ends in rows or in a stated
    /// reason there are none.
    private var isLoading = true
    private var loadTask: Task<Void, Never>?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, InstalledApp>!

    init() {
        super.init(nibName: nil, bundle: nil)
        // Sort and scope sit beside the search field, wherever the field is:
        // in the toolbar on iOS 26, in the navigation bar before it.
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integrated
            toolbarItems = [navigationItem.searchBarPlacementBarButtonItem, .flexibleSpace(), arrangementItem]
        } else {
            navigationItem.rightBarButtonItem = arrangementItem
        }
    }

    /// The menu that orders and narrows the list: by name or identifier, all
    /// apps or only the user's or the system's.
    private lazy var arrangementItem = UIBarButtonItem(
        image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
        menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.arrangementElements() ?? []) },
        ])
    ).then {
        $0.accessibilityLabel = String(localized: "Sort and Filter")
        if #available(iOS 26.0, *) {
            $0.identifier = "arrangement"
            $0.sharesBackground = false
        }
    }

    private func arrangementElements() -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        let sorts = AppSort.allCases.map { sort in
            UIAction(title: sort.title, state: preferences.appSort == sort ? .on : .off) { [weak self] _ in
                AppPreferences.shared.appSort = sort
                self?.apply()
            }
        }
        let scopes = AppScope.allCases.map { scope in
            UIAction(
                title: scope.title,
                image: UIImage(systemName: scope == .all ? "square.grid.2x2" : scope == .user ? "person" : "gearshape"),
                state: preferences.appScope == scope ? .on : .off
            ) { [weak self] _ in
                AppPreferences.shared.appScope = scope
                self?.apply()
            }
        }
        return [
            UIMenu(title: String(localized: "Sort By"), options: .displayInline, children: sorts),
            FilaMenu.selection(title: String(localized: "Applications"), actions: scopes),
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Applications")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        definesPresentationContext = true

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        ).then {
            $0.delegate = self
            $0.keyboardDismissMode = .onDrag
        }
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
        }

        let cell = UICollectionView.CellRegistration<IconRowCell, InstalledApp> { cell, _, app in
            cell.configure(name: app.name, detail: app.bundleIdentifier, image: UIImage(systemName: "app"))
            cell.showApplicationIcon(app.bundleIdentifier, asBadge: false)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, app in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: app)
        }

        collectionView.refreshControl = UIRefreshControl().then {
            $0.addTarget(self, action: #selector(refresh), for: .valueChanged)
        }
        collectionView.alwaysBounceVertical = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshIfVisible),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc private func refreshIfVisible() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self else { return }
        refresh()
    }

    @objc private func refresh() {
        loadTask?.cancel()
        let session = session
        loadTask = Task { [weak self] in
            let apps = await InstalledAppCatalog.load(session: session)
            guard let self, !Task.isCancelled else { return }
            let wasLoaded = !isLoading
            self.apps = apps
            isLoading = false
            apply(animatingDifferences: wasLoaded)
            collectionView.refreshControl?.endRefreshing()
            loadTask = nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
        collectionView.refreshControl?.endRefreshing()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            navigationItem.searchController?.isActive = false
        }
    }

    private var visible: [InstalledApp] {
        let preferences = AppPreferences.shared
        let needle = filter.lowercased()
        let matching = apps.filter { app in
            preferences.appScope.includes(app)
                && (needle.isEmpty
                    || app.name.lowercased().contains(needle)
                    || app.bundleIdentifier.lowercased().contains(needle))
        }
        switch preferences.appSort {
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .identifier:
            return matching.sorted {
                $0.bundleIdentifier.localizedStandardCompare($1.bundleIdentifier) == .orderedAscending
            }
        }
    }

    private func apply(animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, InstalledApp>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
        collectionView.showStatus(status)
    }

    private var status: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        if isLoading {
            return .loading(String(localized: "Loading Installed Apps…"))
        }
        guard apps.isEmpty else {
            return .message(
                symbol: "magnifyingglass",
                title: String(localized: "No Matches"),
                detail: filter.isEmpty
                    ? String(localized: "No apps match this filter. Choose All Apps, User Apps, or System Apps.")
                    : String(localized: "No apps match “\(filter)”. Try a different search.")
            )
        }
        // Reachable through a link after the sidebar row is gone: say why
        // rather than claiming the database would not answer.
        if !SystemCapabilities.showsApplications {
            return .message(
                symbol: "questionmark.app.dashed",
                title: String(localized: "Applications Unavailable"),
                detail: String(localized: "Turn on Show Applications in Settings. If it is already on, Fila cannot see other apps on this device.")
            )
        }
        // Both sources came back empty: the installation database would not
        // answer *and* nothing was under the bundle container root. Saying so
        // is the only way the difference from "you have no apps" is visible.
        return .message(
            symbol: "questionmark.app.dashed",
            title: String(localized: "Unable to List Apps"),
            detail: String(localized: "Fila could not read the list of installed apps. Pull down to refresh.")
        )
    }
}

extension AppListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text ?? ""
        apply()
    }
}

extension AppListViewController: UICollectionViewDelegate {
    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let app = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let locations = app.locations.map { location in
                UIAction(title: location.title, image: UIImage(systemName: location.symbol)) { [weak self] _ in
                    guard let self, let navigation = navigationController,
                          navigation.topViewController === self else { return }
                    // Detail first, unanimated, so Back from the browser lands
                    // where a tap would have: detail, then this list.
                    navigation.pushViewController(AppDetailViewController(app: app), animated: false)
                    navigation.pushViewController(BrowserViewController(directory: location.path), animated: true)
                }
            }
            return UIMenu(title: app.name, children: FilaMenu.groups(locations, [
                UIAction(
                    title: String(localized: "Copy Bundle Identifier"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = app.bundleIdentifier
                },
            ]))
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let app = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(AppDetailViewController(app: app), animated: true)
    }
}
