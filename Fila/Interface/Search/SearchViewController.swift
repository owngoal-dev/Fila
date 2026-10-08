import FilaBackendUI
import FilaProtocol
import SnapKit
import Then
import UIKit

/// One search entry point: this folder or its whole subtree, by name and by
/// filter, searched as the user types.
final class SearchViewController: TabContentViewController {
    enum Scope {
        case folder
        case subfolders
    }

    /// How long typing has to pause before a subtree walk starts. Each
    /// keystroke cancels the walk before it; this keeps a fast typist from
    /// starting and stopping a walk of `/` for every letter.
    private static let typingPause: TimeInterval = 0.3

    private let root: String
    private let session = FileSession.shared
    private let initialQuery: String?
    private var scope: Scope
    private var filter = FileSearchFilter()
    private var matcher = FileSearchMatcher(needle: "", filter: FileSearchFilter())
    /// Subtree walks that ran to their end below the result limit, newest
    /// last, with everything each matched. A search any of them contains —
    /// a longer name, or the name before the last keystroke — is a filter
    /// of those rows rather than another walk, so backspacing does not
    /// empty the list and fill it again.
    private var finished: [(matcher: FileSearchMatcher, hits: [FileSearchResult], skippedLinks: Int)] = []
    private static let finishedLimit = 8
    /// When an empty page may trade what it shows for "Searching…": a walk
    /// that answers sooner goes straight to its result, without a flash of
    /// the loading state between two messages.
    private var revealsLoadingAt = Date.distantPast
    private var shownStatus: StatusView.Content?
    private var showsLoading = false
    private var isCrossfading = false
    private var folderEntries: [FileNode]?
    private var loadingFolderEntries: [FileNode] = []
    private var searchID = UUID()
    private var renderedQuery: String?
    private var renderedScope: Scope?
    private var hits: [FileSearchResult] = []
    private var walk: Task<Void, Never>?
    /// A subtree walk a newer search in this tab stopped; run again when this
    /// page appears.
    private var isInterrupted = false
    /// A walk or a folder listing that Cancel or an interruption stopped
    /// before its end, so Search on the keyboard runs it again.
    private var isStopped = false
    private var isSearching = false
    private var failure: String?
    /// Links to directories the walk passed over. Nonzero means something
    /// below this folder was not searched, and the footer says so.
    private var skippedLinks = 0
    private var currentDirectory = ""
    private var lastProgressDraw = Date.distantPast
    private var lastHitsDraw = Date.distantPast

    private var query: String {
        matcher.needle
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FileSearchResult>!
    /// Stands in for the search field's magnifier while a walk is still
    /// running behind rows that are already on screen.
    private let spinner = UIActivityIndicatorView(style: .medium).then {
        $0.isAccessibilityElement = false
    }

    private var magnifier: UIView?

    /// `scope` nil is the one the user last chose.
    init(root: String, query: String? = nil, scope: Scope? = nil) {
        self.root = root
        initialQuery = query
        self.scope = scope ?? (AppPreferences.shared.searchIncludesSubfolders ? .subfolders : .folder)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
        trailingNavigationItems = [Self.actionsItem(menu: nil)]
        updateMenu()
        // The folder being searched, then this screen; a crumb on the
        // folder or an ancestor goes back to its browser.
        decorationSource = LocalPathDecoration(
            directory: root,
            screen: PathBarView.Crumb(title: title ?? "", icon: UIImage(systemName: "magnifyingglass")),
        )
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
        search.delegate = self
        search.searchBar.delegate = self
        search.searchBar.placeholder = String(localized: "Search file names")
        // A name is matched as typed: `it's` must not become `it’s`.
        search.searchBar.searchTextField.do {
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
        }
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        installSearch(search)
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
                detail: self?.scope == .folder ? nil : FilePresentation.visibleName(hit.directory),
                image: FilePresentation.image(for: hit.node),
                highlight: self?.query,
            )
            cell.showThumbnail(for: hit.path, node: hit.node, session: .shared)
            cell.accessories = hit.node.isNavigable ? [.disclosureIndicator()] : []
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, hit in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: hit)
        }
        // The walk stops at `FileSearch.resultLimit`, and never enters a link;
        // a page that looked complete would be a lie the user cannot detect.
        // The footer exists only while there is something to confess (see
        // `layout(footer:)`).
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter,
        ) { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.plainFooter()
            content.text = self?.footerText
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        search.searchBar.text = initialQuery
        update(needle: initialQuery ?? "")
    }

    /// An empty search page has one thing to do; put the caret in the field.
    /// Only the first time: coming Back to results keeps the keyboard down.
    private var hasActivatedSearch = false
    private var hasOfferedKeyboard = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeWalk()
        guard !hasActivatedSearch else { return }
        hasActivatedSearch = true
        if (initialQuery ?? "").isEmpty {
            // Focus is taken in `didPresentSearchController` once the bar is
            // presented; activation is what presents it.
            navigationItem.searchController?.isActive = true
            navigationItem.searchController?.searchBar.becomeFirstResponder()
        }
    }

    /// From did-appear, not will-appear: an interactive swipe back that is
    /// cancelled sends both pages `viewWillAppear`, and each would restart
    /// its walk and stop the other's over a gesture that went nowhere.
    private func resumeWalk() {
        if isInterrupted {
            startWalk(delay: false)
        } else if walk != nil, scope == .subfolders {
            interruptOtherWalks()
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
        // Whatever the user did elsewhere — a delete in a folder opened from
        // here, a new file from the terminal — the cached results do not know.
        finished = []
        if navigationController?.viewControllers.contains(where: { $0 === self }) != true {
            stopSearch()
        }
    }

    // MARK: - Menu

    /// Where to search, with checkmarks, then what to keep. No Settings:
    /// this menu is the search's form, and Settings is one Back away.
    private func updateMenu() {
        let scopes = [
            (Scope.folder, String(localized: "This Folder")),
            (Scope.subfolders, String(localized: "Include Subfolders")),
        ].map { option, title in
            UIAction(title: title, state: scope == option ? .on : .off) { [weak self] _ in
                self?.selectScope(option)
            }
        }
        let filters = UIMenu(title: String(localized: "Filter"), options: .displayInline, children: [
            filterMenu(String(localized: "Kind"), \.kind, [
                (.any, String(localized: "Any Kind"), nil),
                (.folders, String(localized: "Folders"), nil),
                (.files, String(localized: "Files"), nil),
                (.images, String(localized: "Images"), nil),
                (.videos, String(localized: "Videos"), nil),
                (.audio, String(localized: "Audio"), nil),
                (.text, String(localized: "Text"), nil),
                (.archives, String(localized: "Archives"), nil),
                (.documents, String(localized: "Documents"), nil),
            ]),
            filterMenu(String(localized: "Size"), \.size, FileSearchFilter.Size.allCases.map {
                ($0, Self.title(of: $0), Self.range(of: $0))
            }),
            filterMenu(String(localized: "Date Modified"), \.age, [
                (.any, String(localized: "Any Date"), nil),
                (.today, String(localized: "Today"), nil),
                (.week, String(localized: "Past Week"), nil),
                (.month, String(localized: "Past Month"), nil),
                (.year, String(localized: "Past Year"), nil),
            ]),
        ])
        var sections: [UIMenuElement] = [
            UIMenu(title: String(localized: "Search In"), options: [.displayInline, .singleSelection], children: scopes),
            filters,
        ]
        if filter.isActive {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Clear Filters")) { [weak self] _ in
                    self?.changeFilter { $0 = FileSearchFilter() }
                },
            ]))
        }
        navigationItem.rightBarButtonItem?.menu = UIMenu(children: sections)
    }

    /// One filter as a submenu whose subtitle is its current choice, so the
    /// closed menu still says what is on.
    private func filterMenu<Value: Hashable>(
        _ title: String,
        _ keyPath: WritableKeyPath<FileSearchFilter, Value>,
        _ options: [(Value, String, String?)],
    ) -> UIMenu {
        let selected = filter[keyPath: keyPath]
        let actions = options.map { value, label, detail in
            let action = UIAction(title: label, state: value == selected ? .on : .off) { [weak self] _ in
                self?.changeFilter { $0[keyPath: keyPath] = value }
            }
            // A band's range under its name; iOS 15 shows the name alone.
            if #available(iOS 16.0, *) {
                action.subtitle = detail
            }
            return action
        }
        let menu = UIMenu(title: title, options: .singleSelection, children: actions)
        menu.subtitle = options.first { $0.0 == selected }?.1
        return menu
    }

    private static func title(of size: FileSearchFilter.Size) -> String {
        switch size {
        case .any: String(localized: "Any Size")
        case .empty: String(localized: "Empty")
        case .tiny: String(localized: "Tiny")
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .huge: String(localized: "Huge")
        }
    }

    /// The band in the units the rows show sizes in. Empty needs none.
    private static func range(of size: FileSearchFilter.Size) -> String? {
        guard size != .empty, let bounds = size.bounds else { return nil }
        let lower = FilePresentation.byteLabel(bounds.lower)
        guard let upper = bounds.upper.map(FilePresentation.byteLabel) else {
            return String(localized: "Over \(lower)")
        }
        return bounds.lower == 0 ? String(localized: "Under \(upper)") : String(localized: "\(lower) – \(upper)")
    }

    private func selectScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        AppPreferences.shared.searchIncludesSubfolders = scope == .subfolders
        updateMenu()
        // What the other scope found says nothing complete about this one.
        stopSearch()
        isStopped = false
        finished = []
        update(needle: query)
    }

    private func changeFilter(_ change: (inout FileSearchFilter) -> Void) {
        var filter = filter
        change(&filter)
        guard filter != self.filter else { return }
        self.filter = filter
        updateMenu()
        update(needle: query)
    }

    // MARK: - Searching

    /// Every change to what is searched for — a keystroke, a filter, the
    /// scope — comes here. The rows that still match stay where they are at
    /// once, so the list narrows under the user's typing instead of
    /// emptying; a walk then finds the rest unless the rows already hold it.
    private func update(needle: String, delay: Bool = false) {
        let matcher = FileSearchMatcher(needle: needle, filter: filter)
        self.matcher = matcher
        if scope == .folder {
            if let folderEntries {
                filterFolder(folderEntries)
            } else if walk != nil {
                // Refilter the pages already received while the next one
                // waits; widening must also bring their hidden matches back.
                filterFolder(loadingFolderEntries)
            } else {
                loadFolder()
            }
            return
        }
        if let known = finished.last(where: { matcher.narrows($0.matcher) }) {
            // Stops a walk for the previous name; this one is already known.
            _ = beginSearch()
            isSearching = false
            hits = known.hits.filter { matcher.matches($0.node) }
            skippedLinks = known.skippedLinks
            apply()
        } else {
            hits = matcher.isEmpty ? [] : hits.filter { matcher.matches($0.node) }
            startWalk(delay: delay)
        }
    }

    /// This Folder lists the folder once and filters that listing for every
    /// change after.
    private func loadFolder() {
        let searchID = beginSearch()
        loadingFolderEntries = []
        // Rows a subtree walk found elsewhere are not this folder's; its own
        // stay until the listing lists them again.
        hits.removeAll { $0.directory != root }
        isSearching = true
        holdStatus(for: StatusView.revealDelay)
        apply()
        walk = Task { [weak self] in
            guard let self else { return }
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
                // The failure is the page's status, which rows would hide.
                hits = []
                self.failure = FailureText.summary(for: failure)
            } catch {}
            guard !Task.isCancelled, self.searchID == searchID else { return }
            walk = nil
            isSearching = false
            if let folderEntries {
                filterFolder(folderEntries)
            } else {
                apply()
            }
        }
    }

    /// Stops whatever runs, starts a subtree walk for `matcher`, and keeps
    /// the rows already listed: the walk finds them again and passes over
    /// them, so a row never leaves and comes back.
    private func startWalk(delay: Bool) {
        let searchID = beginSearch()
        let matcher = matcher
        isSearching = !matcher.isEmpty
        if isSearching {
            holdStatus(for: (delay ? Self.typingPause : 0) + StatusView.revealDelay)
        }
        apply()
        guard isSearching else { return }
        interruptOtherWalks()
        walk = Task { [weak self] in
            if delay {
                try? await Task.sleep(nanoseconds: UInt64(Self.typingPause * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.searchID == searchID else { return }
            let listed = Set(hits.map(\.path))
            let skipped = await FileSearch.run(root: root, matcher: matcher, session: session) { directory in
                guard !Task.isCancelled, self.searchID == searchID else { return }
                self.currentDirectory = directory
                guard Date().timeIntervalSince(self.lastProgressDraw) > 0.2 else { return }
                self.lastProgressDraw = Date()
                self.updateStatus()
            } onHit: { hit in
                // Rows kept from before count toward the limit as well.
                guard !Task.isCancelled, self.searchID == searchID, !listed.contains(hit.path),
                      self.hits.count < FileSearch.resultLimit
                else { return }
                self.hits.append(hit)
                // By time, not by count: an apply costs by the rows already
                // listed, and thousands of hits a few at a time would spend
                // the main thread diffing the same list over and over.
                guard self.hits.count == 1 || Date().timeIntervalSince(self.lastHitsDraw) > 0.25 else { return }
                self.lastHitsDraw = Date()
                self.apply()
            }
            guard !Task.isCancelled, self.searchID == searchID else { return }
            skippedLinks = skipped
            walk = nil
            isSearching = false
            if hits.count < FileSearch.resultLimit {
                finished.append((matcher, hits, skipped))
                finished.removeFirst(max(0, finished.count - Self.finishedLimit))
            }
            apply()
        }
    }

    /// Cancels the running search and returns the identity the next one
    /// checks its callbacks against.
    private func beginSearch() -> UUID {
        walk?.cancel()
        walk = nil
        let searchID = UUID()
        self.searchID = searchID
        isInterrupted = false
        isStopped = false
        failure = nil
        // `skippedLinks` stays until the next walk ends: the rows kept on
        // screen are the previous walk's, and so is the footer about them.
        currentDirectory = root
        return searchID
    }

    /// In the order the folder's own page shows: the arrangement dedups by
    /// name, leaves hidden entries out unless they are shown, and sorts by
    /// the browser's key — not in the order the directory was read.
    private func filterFolder(_ entries: [FileNode]) {
        let arrangement = FileArrangement(
            showsHidden: session.showsHidden,
            sortKey: session.sortKey,
            ascending: session.sortAscending,
        )
        let matches = matcher.isEmpty ? [] : entries.filter { matcher.matches($0) }
        hits = arrangement.arrange(matches).map { FileSearchResult(directory: root, node: $0) }
        apply()
    }

    /// Two animations, chosen by the change. Rows a walk appends to a list
    /// already on screen slide in below it. Anything else — the first rows
    /// replacing a message, a narrower name, a different order — crossfades
    /// the whole list: the diffable fade would take most rows out at once
    /// and leave the page white for a few frames, and a crossfade blends
    /// the two pictures instead.
    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileSearchResult>()
        snapshot.appendSections([0])
        snapshot.appendItems(hits)
        let shown = dataSource.snapshot().itemIdentifiers
        // Identity describes the file, not the highlighted query. Retained
        // rows must be configured again even when the result set is unchanged.
        if renderedQuery != query || renderedScope != scope {
            let existing = Set(shown)
            snapshot.reconfigureItems(hits.filter { existing.contains($0) })
        }
        renderedQuery = query
        renderedScope = scope
        let onScreen = view.window != nil
        // A footer that comes or goes changes the layout, which is not an
        // append either.
        let appends = !shown.isEmpty && hits.starts(with: shown) && (footerText != nil) == hasFooterLayout
        let update = { [self] (animatesStatus: Bool) in
            dataSource.apply(snapshot, animatingDifferences: onScreen && appends)
            let showsFooter = footerText != nil
            if showsFooter != hasFooterLayout {
                hasFooterLayout = showsFooter
                collectionView.setCollectionViewLayout(makeLayout(), animated: false)
            } else if showsFooter {
                // Same layout, possibly a new confession: redraw the footer text.
                collectionView.collectionViewLayout.invalidateLayout()
            }
            updateStatus(animated: animatesStatus)
        }
        if !onScreen || appends || (shown.isEmpty && hits.isEmpty) {
            update(true)
        } else {
            crossfade { update(false) }
        }
    }

    /// Blends the list's picture before and after `changes`. One at a time:
    /// a second transition would start again from a half-blended frame, so
    /// a change made while one runs lands in the picture it is fading to.
    private func crossfade(_ changes: @escaping () -> Void) {
        guard view.window != nil, !isCrossfading else {
            changes()
            return
        }
        isCrossfading = true
        UIView.transition(
            with: collectionView,
            duration: 0.2,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: changes,
        ) { [weak self] _ in
            self?.isCrossfading = false
        }
    }

    /// What the list does not show: nil when it is complete. Only a subtree
    /// walk can be cut short or pass over a link; This Folder lists everything.
    private var footerText: String? {
        guard scope == .subfolders, !hits.isEmpty else { return nil }
        var lines: [String] = []
        if hits.count >= FileSearch.resultLimit {
            lines.append(
                String(localized: "Showing the first \(FileSearch.resultLimit) matches. Try a more specific name."),
            )
        }
        if skippedLinks > 0 {
            lines.append(
                String(localized: "Symbolic links were not followed, so items they point to were not searched."),
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
                section.boundarySupplementaryItems = [FileBrowserViewController.footerItem()]
            }
            return section
        }
    }

    /// Keeps the empty page's current message for `delay` before it may
    /// say "Searching…", then looks again.
    private func holdStatus(for delay: TimeInterval) {
        revealsLoadingAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.updateStatus()
        }
    }

    /// `animated` crossfades a change from one panel to another — a message
    /// to "Searching…", a message to nothing — and leaves a changing detail,
    /// such as the folder being searched, to update in place.
    private func updateStatus(animated: Bool = true) {
        // Typing past a message would otherwise flash "Searching…" between
        // it and the next one for every keystroke. Only a message is held:
        // with rows on screen before, there is nothing worth keeping.
        let holds = shownStatus != nil && isSearching && hits.isEmpty && Date() < revealsLoadingAt
        let previous = shownStatus
        if !holds {
            shownStatus = status
            showsLoading = isSearching && hits.isEmpty && failure == nil && !matcher.isEmpty
        }
        // The empty states are read while the keyboard is up; centre them in
        // the band above it instead of behind it.
        let show = { [self] in collectionView.showStatus(shownStatus, followsKeyboard: true) }
        if animated, Self.panel(of: previous) != Self.panel(of: shownStatus) {
            crossfade(show)
        } else {
            show()
        }
        // Wherever the page is not already showing its loading state, the
        // search field's magnifier is the one slot that can say more may
        // come without adding a row.
        let field = navigationItem.searchController?.searchBar.searchTextField
        if isSearching, !showsLoading {
            spinner.startAnimating()
            field?.leftView = spinner
        } else {
            spinner.stopAnimating()
            field?.leftView = magnifier
        }
    }

    private func stopSearch() {
        isStopped = walk != nil
        walk?.cancel()
        walk = nil
        searchID = UUID()
        loadingFolderEntries = []
        isSearching = false
        updateStatus()
    }

    /// One subtree walk per tab: the newest search's. A search pushed over
    /// another — by hand, or by a `fila://search` link, which anything on
    /// the device can send — stops the walks under it, which start again
    /// when their page comes back. Without this, every link stacked another
    /// whole-filesystem walk.
    private func interruptOtherWalks() {
        for case let other as SearchViewController in navigationController?.viewControllers ?? [] where other !== self {
            other.interruptWalk()
        }
    }

    private func interruptWalk() {
        guard walk != nil, scope == .subfolders else { return }
        stopSearch()
        isInterrupted = true
    }

    /// Which panel a status is, for deciding whether a change is a new
    /// panel or new text in the same one.
    private static func panel(of content: StatusView.Content?) -> String? {
        switch content {
        case nil: nil
        case .loading: "loading"
        case let .message(_, _, title, _, _): title
        }
    }

    private var status: StatusView.Content? {
        guard hits.isEmpty else { return nil }
        if let failure {
            return .message(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Unable to Read Folder"),
                detail: failure,
            )
        }
        // Before "Searching…": with nothing typed, a folder still being
        // listed has nothing to search for yet.
        guard !matcher.isEmpty else {
            return .message(
                symbol: "magnifyingglass",
                title: scope == .folder
                    ? String(localized: "Search This Folder")
                    : String(localized: "Search Subfolders"),
                detail: String(localized: "Type a name. Filters in the menu narrow what it finds."),
            )
        }
        if isSearching {
            return .loading(String(localized: "Searching…"), detail: currentDirectory)
        }
        let detail = scope == .folder
            ? String(localized: "Nothing in this folder matches “\(query)”.")
            : String(localized: "Nothing in this folder or its subfolders matches “\(query)”.")
        // A name that is there but filtered out must not read as absent.
        let hint = filter.isActive ? "\n" + String(localized: "Try clearing the filters.") : ""
        return .message(symbol: "magnifyingglass", title: String(localized: "No Matches"), detail: detail + hint)
    }
}

extension SearchViewController: UISearchControllerDelegate {
    /// The keyboard does not follow activation on its own, and at callback
    /// time the presentation transition is still running — a direct
    /// `becomeFirstResponder()` is refused. One runloop turn later the field
    /// accepts the focus. A user-activated bar is already focused, making
    /// this a harmless no-op there.
    func didPresentSearchController(_ searchController: UISearchController) {
        guard !hasOfferedKeyboard else { return }
        hasOfferedKeyboard = true
        DispatchQueue.main.async {
            searchController.searchBar.becomeFirstResponder()
        }
    }
}

extension SearchViewController: UISearchBarDelegate {
    /// Live in both scopes. A keystroke stops a running subtree walk at
    /// once; the next starts when typing pauses.
    func searchBar(_: UISearchBar, textDidChange searchText: String) {
        update(needle: searchText, delay: scope == .subfolders)
    }

    /// The search has already started; Search only puts the keyboard away,
    /// or runs again a walk that Cancel stopped.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard isStopped else { return }
        if scope == .folder {
            loadFolder()
        } else {
            startWalk(delay: false)
        }
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
            navigationController?.pushViewController(FileBrowserViewController(directory: hit.path), animated: true)
        } else {
            Task { await openFile(at: hit.path, session: session) }
        }
    }

    /// The shared file menu also lets a search result reveal its location.
    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var additional: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Reveal in Folder"),
                    image: UIImage(systemName: "folder"),
                ) { [weak self] _ in
                    self?.shell?.follow(.reveal(hit.path))
                },
            ]
            if hit.node.isNavigable {
                additional.append(UIAction(
                    title: String(localized: "Open in New Tab"),
                    image: UIImage(systemName: "plus.square.on.square"),
                ) { [weak self] _ in
                    self?.shell?.openInNewTab(hit.path)
                })
            }
            let actions = FileActions(presenter: self, directory: hit.directory) { [weak self] in
                guard let self else { return }
                hits.removeAll { $0 == hit }
                folderEntries?.removeAll { $0 == hit.node }
                // A rename or a move may have given it a name the next
                // search has to find by walking.
                finished = []
                apply()
            }
            return UIMenu(
                title: hit.node.name,
                children: actions.menuElements(
                    for: hit.path,
                    node: hit.node,
                    additional: additional,
                    preview: { [weak self] in self?.open(hit) },
                ),
            )
        }
    }
}
