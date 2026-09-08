import FilaProtocol
import SnapKit
import Then
import UIKit

/// One search entry point: instant filtering of this folder, or a submitted subtree search.
final class SearchViewController: UIViewController {
    enum Scope {
        case folder
        case subfolders
    }

    private let root: String
    private let session = FileSession.shared
    private let initialQuery: String?
    private var scope: Scope
    private var folderEntries: [FileNode]?
    private var loadingFolderEntries: [FileNode] = []
    private var searchID = UUID()
    private var renderedQuery: String?
    private var renderedScope: Scope?
    private var hits: [FileSearchResult] = []
    private var walk: Task<Void, Never>?
    private var query = ""
    private var isSearching = false
    private var failure: String?
    /// Links to directories the walk passed over. Nonzero means something
    /// below this folder was not searched, and the footer says so.
    private var skippedLinks = 0
    private var currentDirectory = ""
    private var lastProgressDraw = Date.distantPast

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FileSearchResult>!
    /// Stands in for the search field's magnifier while a walk is still
    /// running behind rows that are already on screen.
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var magnifier: UIView?

    init(root: String, query: String? = nil, scope: Scope = .subfolders) {
        self.root = root
        initialQuery = query
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        updateScopeMenu()
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integrated
            // The navigation delegate derives toolbar visibility from these
            // items. Give UIKit's bottom search bar an explicit native slot.
            toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit { walk?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        definesPresentationContext = true

        let search = UISearchController(searchResultsController: nil)
        search.searchBar.delegate = self
        search.searchBar.placeholder = String(localized: "Search file names")
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        magnifier = search.searchBar.searchTextField.leftView

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout()).then {
            $0.delegate = self
            $0.alwaysBounceVertical = true
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

        // This Folder finds everything in the folder the user just left, so a
        // parent path under every row would repeat one fact per hit.
        let cell = UICollectionView.CellRegistration<IconRowCell, FileSearchResult> { [weak self] cell, _, hit in
            cell.configure(
                name: hit.node.name,
                detail: self?.scope == .folder ? nil : hit.directory,
                image: FilePresentation.image(for: hit.node),
                highlight: self?.query
            )
            cell.showThumbnail(for: hit.path, node: hit.node, session: .shared)
            cell.accessories = hit.node.isNavigable ? [.disclosureIndicator()] : []
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, hit in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: hit)
        }
        // The list stops at `FileSearch.resultLimit`, and never enters a link;
        // a page that looked complete would be a lie the user cannot detect.
        // The footer exists only while there is something to confess (see
        // `layout(footer:)`).
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.plainFooter()
            content.text = self?.footerText
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        search.searchBar.text = initialQuery
        start(initialQuery ?? "")
    }

    /// An empty search page has one thing to do; put the caret in the field.
    /// Only the first time: coming Back to results keeps the keyboard down.
    private var hasOfferedKeyboard = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasOfferedKeyboard else { return }
        hasOfferedKeyboard = true
        if (initialQuery ?? "").isEmpty {
            navigationItem.searchController?.searchBar.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Deactivate only when navigation leaves this page, not when the
        // search controller itself is being presented. Keep its query and
        // results attached so Back does not rebuild the search interface.
        if isMovingFromParent
            || navigationController?.topViewController !== self
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
        {
            navigationItem.searchController?.isActive = false
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.viewControllers.contains(where: { $0 === self }) != true {
            stopSearch()
        }
    }

    private func updateScopeMenu() {
        let options: [(Scope, String)] = [
            (.folder, String(localized: "This Folder")),
            (.subfolders, String(localized: "Subfolders")),
        ]
        let actions = options.map { option, title in
            UIAction(
                title: title,
                image: UIImage(systemName: option == .folder ? "folder" : "square.stack.3d.up"),
                state: scope == option ? .on : .off
            ) { [weak self] _ in
                self?.selectScope(option)
            }
        }
        navigationItem.rightBarButtonItem?.menu = UIMenu(children: [
            FilaMenu.selection(title: String(localized: "Search In"), actions: actions),
        ])
    }

    private func selectScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        updateScopeMenu()
        // A subtree walk is deliberate; switching the scope must not start one.
        start(scope == .folder ? navigationItem.searchController?.searchBar.text ?? "" : "")
    }

    private func start(_ needle: String) {
        walk?.cancel()
        walk = nil
        let searchID = UUID()
        self.searchID = searchID
        loadingFolderEntries = []
        hits = []
        query = needle
        failure = nil
        skippedLinks = 0
        currentDirectory = root
        isSearching = scope == .folder ? folderEntries == nil : !needle.isEmpty
        if scope == .folder, let folderEntries {
            filterFolder(folderEntries)
            return
        }
        apply()
        guard isSearching else { return }
        walk = Task { [weak self, scope] in
            guard let self, !Task.isCancelled, self.searchID == searchID else { return }
            if scope == .folder {
                do {
                    for try await page in DirectoryReader.pages(in: root, session: session) {
                        guard !Task.isCancelled, self.searchID == searchID else { return }
                        guard page.count <= DirectoryReader.maximumEntryCount - loadingFolderEntries.count else {
                            throw FilaFailure(errno: E2BIG, path: root)
                        }
                        loadingFolderEntries.append(contentsOf: page)
                        filterFolder(loadingFolderEntries)
                    }
                    guard !Task.isCancelled, self.searchID == searchID else { return }
                    folderEntries = loadingFolderEntries
                    loadingFolderEntries = []
                } catch let failure as FilaFailure {
                    guard !Task.isCancelled, self.searchID == searchID else { return }
                    self.failure = FailureText.summary(for: failure)
                } catch {}
            } else {
                let skipped = await FileSearch.run(
                    root: root,
                    needle: needle,
                    session: session
                ) { directory in
                    guard !Task.isCancelled, self.searchID == searchID else { return }
                    self.currentDirectory = directory
                    guard Date().timeIntervalSince(self.lastProgressDraw) > 0.2 else { return }
                    self.lastProgressDraw = Date()
                    self.updateStatus()
                } onHit: { hit in
                    guard !Task.isCancelled, self.searchID == searchID else { return }
                    self.hits.append(hit)
                    if self.hits.count % 20 == 0 {
                        self.apply()
                    }
                }
                guard !Task.isCancelled, self.searchID == searchID else { return }
                skippedLinks = skipped
            }
            guard !Task.isCancelled, self.searchID == searchID else { return }
            walk = nil
            isSearching = false
            apply()
        }
    }

    private func filterFolder(_ entries: [FileNode]) {
        var names = Set<String>()
        hits = entries.filter {
            names.insert($0.name).inserted
                && (AppPreferences.shared.showsHidden || !$0.isHidden)
                && !query.isEmpty && $0.name.localizedStandardContains(query)
        }.map { FileSearchResult(directory: root, node: $0) }
        apply()
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileSearchResult>()
        snapshot.appendSections([0])
        snapshot.appendItems(hits)
        // Identity describes the file, not the highlighted query. Retained
        // rows must be configured again even when the result set is unchanged.
        if renderedQuery != query || renderedScope != scope {
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(hits.filter { existing.contains($0) })
        }
        renderedQuery = query
        renderedScope = scope
        dataSource.apply(snapshot, animatingDifferences: false)
        let showsFooter = footerText != nil
        if showsFooter != hasFooterLayout {
            hasFooterLayout = showsFooter
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        } else if showsFooter {
            // Same layout, possibly a new confession: redraw the footer text.
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateStatus()
    }

    /// What the list does not show: nil when it is complete. Only a subtree
    /// walk can be cut short or pass over a link; This Folder lists everything.
    private var footerText: String? {
        guard scope == .subfolders, !hits.isEmpty else { return nil }
        var lines: [String] = []
        if hits.count >= FileSearch.resultLimit {
            lines.append(
                String(localized: "Showing the first \(FileSearch.resultLimit) matches. Try a more specific name.")
            )
        }
        if skippedLinks > 0 {
            lines.append(
                String(localized: "Symbolic links were not followed, so items they point to were not searched.")
            )
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var hasFooterLayout = false

    /// Built like the browser's list: `footerMode` on a plain list pins its
    /// footer to the visible bounds, and this one has to end the list, not
    /// hover over the last rows.
    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        let footer = hasFooterLayout
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if footer {
                section.boundarySupplementaryItems = [BrowserViewController.footerItem()]
            }
            return section
        }
    }

    private func updateStatus() {
        collectionView.showStatus(status)
        // Empty results already show their own loading indicator. Once hits
        // arrive, the only remaining question is whether more may come, and
        // the search field's magnifier is the one slot that can say so
        // without adding a row.
        let field = navigationItem.searchController?.searchBar.searchTextField
        if isSearching, !hits.isEmpty {
            spinner.startAnimating()
            field?.leftView = spinner
        } else {
            spinner.stopAnimating()
            field?.leftView = magnifier
        }
    }

    private func stopSearch() {
        walk?.cancel()
        walk = nil
        searchID = UUID()
        loadingFolderEntries = []
        isSearching = false
        updateStatus()
    }

    private var status: StatusView.Content? {
        guard hits.isEmpty else { return nil }
        if let failure {
            return .message(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Unable to Read Folder"),
                detail: failure
            )
        }
        if isSearching {
            return .loading(String(localized: "Searching…"), detail: currentDirectory)
        }
        guard !query.isEmpty else {
            return .message(
                symbol: "magnifyingglass",
                title: scope == .folder
                    ? String(localized: "Search This Folder")
                    : String(localized: "Search Subfolders"),
                detail: scope == .subfolders
                    ? String(localized: "Enter a name, then tap Search to include subfolders.")
                    : nil
            )
        }
        let detail = scope == .folder
            ? String(localized: "Nothing in this folder matches “\(query)”.")
            : String(localized: "Nothing in this folder or its subfolders matches “\(query)”.")
        return .message(symbol: "magnifyingglass", title: String(localized: "No Matches"), detail: detail)
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBar(_: UISearchBar, textDidChange searchText: String) {
        guard scope == .folder else {
            start("")
            return
        }
        query = searchText
        if let folderEntries {
            filterFolder(folderEntries)
        } else if isSearching {
            // Refilter the pages already received while the next one waits;
            // widening the query must also bring their hidden matches back.
            filterFolder(loadingFolderEntries)
        } else {
            start(searchText)
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        start(searchBar.text ?? "")
    }

    func searchBarCancelButtonClicked(_: UISearchBar) {
        stopSearch()
    }
}

extension SearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return }
        open(hit)
    }

    private func open(_ hit: FileSearchResult) {
        if hit.node.isNavigable {
            navigationController?.pushViewController(BrowserViewController(directory: hit.path), animated: true)
        } else {
            Task { await openFile(at: hit.path, session: session) }
        }
    }

    /// The shared file menu also lets a search result reveal its location.
    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var additional: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Reveal in Folder"),
                    image: UIImage(systemName: "folder")
                ) { [weak self] _ in
                    self?.shell?.follow(.reveal(hit.path))
                },
            ]
            if hit.node.isNavigable {
                additional.append(UIAction(
                    title: String(localized: "Open in New Tab"),
                    image: UIImage(systemName: "plus.square.on.square")
                ) { [weak self] _ in
                    self?.shell?.openInNewTab(hit.path)
                })
            }
            let actions = FileActions(presenter: self, directory: hit.directory) { [weak self] in
                guard let self else { return }
                hits.removeAll { $0 == hit }
                folderEntries?.removeAll { $0 == hit.node }
                apply()
            }
            return UIMenu(
                title: hit.node.name,
                children: actions.menuElements(
                    for: hit.path,
                    node: hit.node,
                    additional: additional,
                    preview: { [weak self] in self?.open(hit) }
                )
            )
        }
    }
}
