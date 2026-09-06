import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// One directory.
///
/// Navigating into a subdirectory pushes another of these onto the same
/// navigation controller, which is what makes the same class work as the
/// supplementary column on iPad and as the push stack on iPhone without a
/// second code path.
final class BrowserViewController: UIViewController {
    let directory: String

    let session = FileSession.shared

    /// The trash itself. Its rows are put back or emptied, never opened,
    /// created or pasted into. Computed, not stored: a tab restored at launch
    /// exists before the handshake does.
    var isTrash: Bool { FileActions.isTrash(directory) }

    /// The displayed listing. Initial pages append as they arrive; a refresh
    /// replaces it on completion. `visible` applies preferences and sorting.
    private(set) var entries: [FileNode] = []
    private var visible: [FileNode] = []
    private var loadTask: Task<Void, Never>?
    private var appFolders: [String: AppFolderPresentation] = [:]
    private var volume: VolumeInfo?
    /// The directory listing has not finished yet. Only the first load replaces
    /// the initial empty view with a loading panel.
    private(set) var isListing = false
    /// Why the listing stopped, when it stopped before a single row arrived.
    /// A failure partway through a listing is reported as an alert instead —
    /// there are rows on screen by then, and the empty panel is not visible to
    /// carry it.
    private var listingFailure: FilaFailure?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FileNode>!
    private let pathBar = PathBarView()
    private lazy var pathBarItem = UIBarButtonItem(customView: pathBar)
    private var pathBarWidth: Constraint?
    private let clipboardBar = ClipboardBarView()
    private let refresher = UIRefreshControl()
    /// The list's own footer, once one has been dequeued. Weak because the
    /// collection view owns it and may recycle it; nil simply means there is
    /// nothing on screen to write the volume into yet.
    private weak var footerView: BrowserFooterView?
    /// What the footer says. Held here rather than read out of the footer view,
    /// because the view comes and goes with the layout and the text does not.
    private var footerText: String?
    /// The folder title remains stable when selection changes. The trash is
    /// named for what it is, not for its dot-directory.
    private var folderTitle: String {
        if directory == "/" { return String(localized: "Root") }
        if isTrash { return String(localized: "Trash") }
        return URL(fileURLWithPath: directory).lastPathComponent
    }

    /// An entry a `fila://reveal` link asked for, cleared the first time it is
    /// found. It survives across pages because the listing streams: the row it
    /// names may be on the fourth page, or on none of them.
    private var pendingSelection: String?

    /// Where this folder was left when its tab was last put away. Applied once,
    /// after the first page lands — before that there is nothing to scroll.
    /// Set by the tab container, which is the only thing that knows a tab is
    /// being rebuilt rather than opened.
    var restoredScrollOffset: Double?

    /// Where this folder is scrolled to now.
    ///
    /// A pending restore outranks the live offset, and that ordering is the
    /// whole point: a rebuilt tab is asked where it is the moment it appears,
    /// which is before its first page has landed and therefore before it has
    /// anywhere to scroll to. Answering with the zero it is sitting at would
    /// overwrite the position being restored with the top of the folder.
    var scrollOffset: Double {
        if let restoredScrollOffset { return restoredScrollOffset }
        return isViewLoaded ? Double(collectionView.contentOffset.y) : 0
    }

    /// `select` is the name of an entry to highlight once it arrives — how
    /// `fila://reveal` lands on the right row. It is a name and not an index
    /// because the listing streams in pages, so the row does not exist yet when
    /// this controller is built, and it may never exist at all.
    init(directory: String, select: String? = nil) {
        self.directory = directory
        pendingSelection = select
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = folderTitle
        configureNavigationItem()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    deinit { loadTask?.cancel() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = folderTitle
        buildHierarchy()
        buildDataSource()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(jobFinished(_:)),
            name: .filaJobFinished,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged(_:)),
            name: .filaPreferencesChanged,
            object: nil
        )

        for name in [Notification.Name.filaClipboardChanged, .filaTabsChanged, .filaSidebarChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshToolbar), name: name, object: nil)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil
        )

        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The path is part of the native toolbar. Only the clipboard floats
        // above that safe area and needs an additional scrolling inset.
        let clipboardHeight = clipboardBar.isHidden ? 0 : clipboardBar.bounds.height
        if collectionView.contentInset.bottom != clipboardHeight {
            collectionView.contentInset.bottom = clipboardHeight
            collectionView.verticalScrollIndicatorInsets.bottom = clipboardHeight
        }
        updatePathBarWidth()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateChrome()
        // Initialize the shared operation observer when a browser first appears.
        _ = session.operations
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pathBar.revealCurrentComponent()
        AppPreferences.shared.lastDirectory = directory
    }

    /// Only explicit use records a directory; appearing or dwelling never does.
    /// Rows already received count even while a large listing is still streaming.
    func recordDirectoryUse() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self,
              listingFailure == nil, !isListing || !entries.isEmpty else { return }
        AppPreferences.shared.noteVisit(directory)
    }

    @objc private func sceneDidEnterBackground(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        recordDirectoryUse()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            refreshToolbar()
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        let modeChanged = editing != isEditing
        if editing, modeChanged { recordDirectoryUse() }
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        view.setNeedsLayout()
        // Edit mode borrows the left slot for Cancel. A split view puts its
        // own items there, so what was there is put back rather than cleared.
        if editing, borrowedLeftItems == nil { borrowedLeftItems = navigationItem.leftBarButtonItems ?? [] }
        if !editing {
            collectionView.indexPathsForSelectedItems?.forEach {
                collectionView.deselectItem(at: $0, animated: false)
            }
        }
        updateChrome(animated: animated && modeChanged)
    }

    /// A view preference changed here: refresh the way this change wants to be
    /// refreshed, then tell every other browser in the stack. The preferences
    /// are global even when the menu that changed one belonged to this folder,
    /// and a browser further back that keeps its old layout while dequeuing
    /// cells for the new one draws a mix of both.
    func viewPreferenceChanged(relayout: Bool) {
        recordDirectoryUse()
        if relayout { applyLayoutPreference() } else { applySnapshot(animated: true) }
        NotificationCenter.default.post(name: .filaPreferencesChanged, object: self)
    }

    /// Nil sender means it came from Settings, which has no browser of its own.
    @objc private func preferencesChanged(_ note: Notification) {
        guard note.object as AnyObject? !== self else { return }
        applyLayoutPreference()
        // App folders draw LaunchServices names only while Applications is on;
        // rows decorated under the old setting need a re-list, nothing else does.
        if decoratedWithApplications != SystemCapabilities.showsApplications {
            decoratedWithApplications = SystemCapabilities.showsApplications
            reload()
        }
    }

    /// The Applications setting the rows on screen were decorated under —
    /// recorded when the decoration is looked up, not when the browser is
    /// made, so the first toggle after listing is seen as a change.
    private var decoratedWithApplications = SystemCapabilities.showsApplications

    // MARK: - Hierarchy

    private func buildHierarchy() {
        pathBar.onSelect = { [weak self] path in self?.open(directory: path) }
        let folder = UIImage(named: "FileIcons/folder")
        pathBar.setPath(directory) { _ in folder }
        // An app bundle or container wears its app's icon, the same as its
        // row does; the lookup is async, so the folder stands in first.
        Task { [weak self, directory] in
            let apps = await InstalledAppCatalog.load(session: .shared)
            let presentation = AppFolderDisplay.presentationLookup(for: apps)
            // Warm every crumb's artwork first: the bar draws synchronously.
            var prefix = ""
            for component in directory.split(separator: "/") {
                prefix += "/" + component
                if let identifier = presentation(prefix)?.applicationIdentifier { _ = await AppFolderDisplay.icon(for: identifier) }
            }
            guard let self else { return }
            self.pathBar.setPath(self.directory) { path in
                guard let identifier = presentation(path)?.applicationIdentifier else { return folder }
                return AppFolderDisplay.cachedIcon(for: identifier) ?? folder
            }
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout()).then {
            $0.delegate = self
            $0.dragDelegate = self
            $0.dropDelegate = self
            $0.dragInteractionEnabled = true
            $0.allowsMultipleSelectionDuringEditing = true
            $0.alwaysBounceVertical = true
            $0.refreshControl = refresher
        }
        refresher.addAction(UIAction { [weak self] _ in self?.commandRefresh() }, for: .valueChanged)

        clipboardBar.onShow = { [weak self] in self?.presentClipboard() }
        clipboardBar.onPaste = { [weak self] in self?.paste() }
        clipboardBar.onClear = { FileClipboard.shared.clear() }

        // The toolbar owns the breadcrumb's material and layout. Its custom
        // view receives only the width left after Search, Tabs and their gaps.
        pathBar.contentInsetAdjustmentBehavior = .never
        pathBar.snp.makeConstraints { make in
            pathBarWidth = make.width.equalTo(FilaUI.minimumTapTarget).constraint
            make.height.equalTo(FilaUI.minimumTapTarget)
        }
        if #available(iOS 26.0, *) {
            pathBarItem.identifier = "path"
            pathBarItem.sharesBackground = false
        }
        view.addSubview(collectionView)
        view.addSubview(clipboardBar)
        // The list runs under both bars: the safe area supplies the insets,
        // and on iOS 26 each scroll edge fades the rows out under the glass
        // instead of clipping them at the bar's edge.
        collectionView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
        clipboardBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
        }
    }

    private func configureNavigationItem() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = moreItem()
        toolbarItems = browsingToolbar
    }

    // MARK: - Layout

    /// The volume line, as a layout item.
    ///
    /// Built here rather than left to `UICollectionLayoutListConfiguration`'s
    /// `footerMode`: a *plain* list pins its supplementary views to the visible
    /// bounds, which is exactly the floating bar this replaced — it would have
    /// hovered over the last row instead of ending the list.
    static func footerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(44)
            ),
            elementKind: UICollectionView.elementKindSectionFooter,
            alignment: .bottom
        )
    }

    private func makeLayout() -> UICollectionViewLayout {
        switch AppPreferences.shared.layout(for: directory) {
        case .list:
            let configuration = UICollectionLayoutListConfiguration(appearance: .plain).with {
                // A list section draws a background decoration *over* the
                // collection view's `backgroundView` — which is where the
                // empty/loading panel lives. Clearing it is what keeps "Reading
                // this folder…" visible; the cells carry their own background.
                $0.backgroundColor = .clear
                $0.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    guard let self, let node = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
                    let title = self.isTrash ? String(localized: "Delete Permanently") : self.deleteTitle
                    let delete = UIContextualAction(style: .destructive, title: title) { _, _, done in
                        self.delete([self.path(of: node)])
                        done(true)
                    }
                    delete.image = UIImage(systemName: "trash")
                    return UISwipeActionsConfiguration(actions: [delete])
                }
            }
            return UICollectionViewCompositionalLayout { _, environment in
                let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                section.boundarySupplementaryItems = [Self.footerItem()]
                return section
            }
        case .grid:
            return UICollectionViewCompositionalLayout { _, environment in
                let columns = max(2, Int(environment.container.effectiveContentSize.width / 112))
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)
                ))
                let height = 84 + UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    subitem: item, count: columns
                )
                group.interItemSpacing = .fixed(FilaUI.Spacing.small)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = FilaUI.Spacing.small
                section.contentInsets = .init(top: FilaUI.Spacing.small, leading: FilaUI.Spacing.medium, bottom: FilaUI.Spacing.small, trailing: FilaUI.Spacing.medium)
                section.boundarySupplementaryItems = [Self.footerItem()]
                return section
            }
        }
    }

    private func buildDataSource() {
        let listCell = UICollectionView.CellRegistration<IconRowCell, FileNode> { [weak self] cell, _, node in
            guard let self else { return }
            cell.configure(node, presentation: self.appFolders[node.name])
            cell.showThumbnail(for: self.path(of: node), node: node, session: self.session)
        }

        let gridCell = UICollectionView.CellRegistration<BrowserGridCell, FileNode> { [weak self] cell, _, node in
            guard let self else { return }
            cell.configure(node: node, path: self.path(of: node), session: self.session, presentation: self.appFolders[node.name])
        }

        let footer = UICollectionView.SupplementaryRegistration<BrowserFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            guard let self else { return }
            self.footerView = view
            view.label.text = self.footerText
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [directory] collection, indexPath, node in
            switch AppPreferences.shared.layout(for: directory) {
            case .list:
                return collection.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: node)
            case .grid:
                return collection.dequeueConfiguredReusableCell(using: gridCell, for: indexPath, item: node)
            }
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// Re-reads every view preference and redraws from scratch.
    ///
    /// `applySnapshotUsingReloadData` rather than a plain apply: the item set is
    /// usually identical, and an identical snapshot is an empty diff that never
    /// asks the cell provider for anything. That would leave list cells laid out
    /// in grid geometry after a layout change, and gigabytes still spelled in GB
    /// after the units changed.
    func applyLayoutPreference() {
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        visible = arrange(entries)
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileNode>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible)
        dataSource.applySnapshotUsingReloadData(snapshot)
        collectionView.showStatus(status) { [weak self] in self?.createTrash() }
        updateChrome()
    }

    /// What the list says about itself when it has no rows to show.
    ///
    /// Five endings, one of which is not an ending at all — and before this
    /// they were the same blank rectangle. The order is the order the facts
    /// override each other in: a refusal outranks a wait, a wait outranks
    /// anything about the contents, and "empty" is only true once the listing
    /// has actually finished saying so.
    private var status: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        if let listingFailure {
            // The trash is made by the first delete, so a missing one is not
            // a broken folder: say what it is for, and offer to make it now.
            if isTrash, listingFailure.code == .notFound || listingFailure.systemError == ENOENT {
                return .message(
                    symbol: "trash", artwork: "trash-empty-large",
                    title: String(localized: "No Trash Yet"),
                    detail: String(localized: "Deleted items are moved here so they can be put back. Create it now, or Fila creates it with your first delete."),
                    button: String(localized: "Create Trash")
                )
            }
            return .message(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Unable to Read Folder"),
                detail: FailureText.summary(for: listingFailure)
            )
        }
        // No detail: the daemon may still be launching, and there is nothing
        // here a user could act on — the same reason the connecting panel
        // offers nothing but the word.
        if isListing { return .loading(String(localized: "Reading Folder…")) }
        if !entries.isEmpty {
            return .message(
                symbol: "eye.slash",
                title: String(localized: "Only Hidden Items"),
                detail: String(localized: "Turn on Show Hidden Files to see them.")
            )
        }
        if isTrash {
            return .message(
                symbol: "trash", artwork: "trash-empty-large",
                title: String(localized: "Trash Is Empty"),
                detail: String(localized: "Deleted items are moved here so they can be put back.")
            )
        }
        return .message(symbol: "folder", title: String(localized: "Folder Is Empty"))
    }

    /// The trash, made on request the way the first delete would make it: a
    /// directory of the backend's own, 0700.
    private func createTrash() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.perform { link in
                    try await link.create(.directory, at: self.directory)
                    try await link.setAttributes(AttributeChange(mode: 0o700), at: self.directory)
                }
                self.reload()
            } catch let failure as FilaFailure {
                self.report(failure)
            } catch {}
        }
    }

    // MARK: - Loading

    /// Reloads the directory, page by page.
    ///
    /// The first page lands on screen before the second is asked for, which is
    /// the whole reason listings are paged: a directory with 100k entries has to
    /// feel instant even though it is two hundred round trips. A refresh keeps
    /// existing rows until the complete listing can replace them in one diff.
    func reload() {
        // A completed task remains here, so a loaded empty folder also keeps
        // its current presentation when another request starts.
        let keepsContent = loadTask != nil
        loadTask?.cancel()
        listingFailure = nil
        isListing = true
        if !keepsContent {
            appFolders = [:]
            applySnapshot(animated: false)
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            var pending: [FileNode] = []
            var lastApply = Date.distantPast
            var animateSnapshot = false
            do {
                for try await page in DirectoryReader.pages(in: self.directory, session: self.session) {
                    // Only the latest reload owns the rows. During a refresh,
                    // a partial listing must not remove later pages.
                    guard !Task.isCancelled else { return }
                    pending.append(contentsOf: page)
                    guard !keepsContent else { continue }
                    // ponytail: re-sorting the accumulated list on every apply is
                    // O(n log n) per batch; the throttle is what keeps that off
                    // the critical path. A merge into the sorted array is the fix
                    // if a huge directory ever feels slow while it loads.
                    guard Date().timeIntervalSince(lastApply) > 0.15 else { continue }
                    self.entries.append(contentsOf: pending)
                    pending = []
                    lastApply = Date()
                    self.applySnapshot(animated: false)
                }
                guard !Task.isCancelled else { return }
                if keepsContent {
                    let names = Set(pending.lazy.map(\.name))
                    animateSnapshot = self.visible.contains { !names.contains($0.name) }
                    self.entries = pending
                } else {
                    self.entries.append(contentsOf: pending)
                }
            } catch let failure as FilaFailure {
                guard !Task.isCancelled else { return }
                // With nothing on screen the refusal *is* the screen, and an
                // alert dismissed over a blank list leaves the user with the
                // blank list. With rows already listed it is a refresh that
                // went wrong halfway, which nothing on screen would show.
                if self.entries.isEmpty {
                    self.listingFailure = failure
                } else {
                    self.report(failure)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self.isListing = false
            await withCheckedContinuation { continuation in
                self.applySnapshot(animated: animateSnapshot) { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            self.refresher.endRefreshing()
            self.decoratedWithApplications = SystemCapabilities.showsApplications
            let appFolders = await AppFolderDisplay.load(in: self.directory, entries: self.entries, session: self.session)
            guard !Task.isCancelled else { return }
            let refreshAppFolders = !self.appFolders.isEmpty || !appFolders.isEmpty
            self.appFolders = appFolders
            if refreshAppFolders {
                var snapshot = self.dataSource.snapshot()
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
                await self.dataSource.apply(snapshot, animatingDifferences: false)
            }
            guard !Task.isCancelled else { return }
            await self.loadVolume()
        }
    }

    private func loadVolume() async {
        let volume = try? await session.perform(retryOnDisconnect: true) { try await $0.volumeInfo(for: directory) }
        guard !Task.isCancelled else { return }
        self.volume = volume
        updateFooter()
    }

    @objc private func jobFinished(_ note: Notification) {
        guard let paths = note.object as? [String], paths.contains(directory) else { return }
        reload()
    }

    // MARK: - Snapshot

    /// Scroll a revealed entry into view and select it, once the page carrying
    /// it has landed. Hidden entries are a real case here: a link can name a
    /// dotfile the browser is currently filtering out, and revealing it means
    /// showing it, not silently doing nothing.
    private func revealPendingSelectionIfArrived() {
        guard let name = pendingSelection else { return }
        guard let index = visible.firstIndex(where: { $0.name == name }) else {
            if !AppPreferences.shared.showsHidden, entries.contains(where: { $0.name == name }) {
                AppPreferences.shared.showsHidden = true
                applySnapshot(animated: false)
            }
            return
        }
        pendingSelection = nil
        let path = IndexPath(item: index, section: 0)
        collectionView.selectItem(at: path, animated: true, scrollPosition: .centeredVertically)
    }

    /// Puts a restored tab back where it was, once there is enough listed to
    /// scroll. Tried again on every page for the same reason the reveal is: the
    /// listing streams, and a folder that is two pages tall has nowhere to go
    /// while only the first has landed.
    private func restoreScrollOffsetIfArrived() {
        guard let offset = restoredScrollOffset, !visible.isEmpty else { return }
        guard offset > 0 else {
            restoredScrollOffset = nil
            return
        }
        collectionView.layoutIfNeeded()
        let insets = collectionView.adjustedContentInset
        let reachable = collectionView.contentSize.height + insets.top + insets.bottom - collectionView.bounds.height
        guard reachable > 0 else { return }
        restoredScrollOffset = nil
        collectionView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(offset), reachable - insets.top)), animated: false)
    }

    func applySnapshot(animated: Bool, completion: (() -> Void)? = nil) {
        visible = arrange(entries)
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileNode>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible)
        dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        collectionView.showStatus(status) { [weak self] in self?.createTrash() }
        revealPendingSelectionIfArrived()
        restoreScrollOffsetIfArrived()
        // Every page of a long listing lands here, so outside edit mode this
        // only refreshes the footer — rebuilding the whole toolbar per page
        // would be work nobody sees.
        updateFooter()
        if isEditing { updateChrome() }
    }

    private func arrange(_ nodes: [FileNode]) -> [FileNode] {
        let preferences = AppPreferences.shared
        // Deduplicated by name: pages are read from a directory that is live,
        // and one name arriving twice would put two rows with the same identity
        // into the snapshot, which is a crash rather than a glitch.
        var seen = Set<String>()
        var items = nodes.filter { seen.insert($0.name).inserted }
        if !preferences.showsHidden { items.removeAll(where: \.isHidden) }
        return items.sorted(by: precedes)
    }

    /// Directories first regardless of direction — reversing that puts the way
    /// out of a folder at the bottom of a hundred thousand files.
    private func precedes(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isNavigable != rhs.isNavigable { return lhs.isNavigable }
        let preferences = AppPreferences.shared
        let order: ComparisonResult
        switch preferences.sortKey {
        case .name: order = lhs.name.localizedStandardCompare(rhs.name)
        case .date: order = compare(lhs.modified, rhs.modified)
        case .size: order = compare(lhs.size, rhs.size)
        case .kind: order = FilePresentation.sortKind(for: lhs).compare(FilePresentation.sortKind(for: rhs))
        }
        guard order != .orderedSame else {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return preferences.isAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    /// How many items, and what is left on the volume they are on.
    ///
    /// The count moved here when the sort strip lost its second half: it is a
    /// fact about the contents of the list, and the end of the list is where
    /// you are already looking when you want it.
    private func updateFooter() {
        // An empty list already has the status panel explaining itself in the
        // middle of the screen; a line saying "0 items" under the header is the
        // same fact, worse placed.
        guard !visible.isEmpty else {
            setFooter("")
            return
        }
        var parts = [String(localized: "\(visible.count) items")]
        if let volume {
            let free = FilePresentation.byteLabel(volume.availableByteCount)
            let total = FilePresentation.byteLabel(volume.totalByteCount)
            parts.append(String(localized: "\(free) free of \(total)"))
            // Last, so it sits at the right end of the line: nothing in this
            // folder can be changed, and the daemon's root does not help.
            if volume.isReadOnly { parts.append(String(localized: "Read Only")) }
        }
        setFooter(parts.joined(separator: " · "))
    }

    /// Straight onto the view when there is one, rather than through the
    /// snapshot. A listing lands here once per page and reloading a section to
    /// change one label would rebuild every visible row with it.
    private func setFooter(_ text: String) {
        guard footerText != text else { return }
        footerText = text
        footerView?.label.text = text
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private var selectedCount: Int { collectionView.indexPathsForSelectedItems?.count ?? 0 }

    /// What was in the navigation item's left slot before edit mode borrowed it.
    private var borrowedLeftItems: [UIBarButtonItem]?

    /// Selection actions borrow the left item and replace the normal toolbar.
    private func updateChrome(animated: Bool = false) {
        guard isViewLoaded, navigationController?.topViewController === self else { return }
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationController?.setToolbarHidden(false, animated: false)
        // Selection has one exit, Cancel. Outside selection UIKit supplies
        // Back from the real stack, alongside the iPad's sidebar control.
        navigationItem.setHidesBackButton(isEditing, animated: animated)
        clipboardBar.isHidden = isEditing || isTrash || FileClipboard.shared.isEmpty
        clipboardBar.configure(FileClipboard.shared)

        guard isEditing else {
            navigationItem.title = folderTitle
            if let borrowed = borrowedLeftItems {
                navigationItem.leftBarButtonItems = borrowed.isEmpty ? nil : borrowed
                borrowedLeftItems = nil
                // The split view may have collapsed or expanded meanwhile.
                shell?.configureSidebarButton(for: self)
            }
            navigationItem.rightBarButtonItem = moreItem()
            rebuildBrowsingToolbar(animated: animated)
            updateFooter()
            return
        }

        // Selection mode: the title counts, the bar holds the actions as
        // buttons rather than a menu, and the trailing item is gone — nothing
        // it offered is missing from the bar.
        let count = selectedCount
        navigationItem.title = count == 0 ? String(localized: "Select Items") : String(localized: "\(count) Selected")
        let cancel = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in
            self?.setEditing(false, animated: true)
        })
        cancel.accessibilityLabel = String(localized: "Cancel")
        navigationItem.leftBarButtonItems = [cancel]
        navigationItem.rightBarButtonItem = nil

        let items = selectionToolbar
        let allSelected = count == visible.count && !visible.isEmpty
        items.selectAll.image = UIImage(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
        items.selectAll.accessibilityLabel = allSelected ? String(localized: "Deselect All") : String(localized: "Select All")
        items.selectAll.isEnabled = !visible.isEmpty
        items.delete.image = UIImage(systemName: "trash")
        items.delete.accessibilityLabel = isTrash ? String(localized: "Delete Permanently") : deleteTitle
        for item in [items.copy, items.move, items.compress, items.putBack, items.delete] { item.isEnabled = count > 0 }

        // A count update changes the existing controls without replacing the
        // toolbar, including when select(_:) follows entry into selection mode.
        guard toolbarItems?.first !== items.selectAll else { return }
        if isTrash {
            // Two verbs in the trash: back where it came from, or gone for good.
            setToolbarItems([items.selectAll, .flexibleSpace(), items.putBack, .flexibleSpace(), items.delete], animated: false)
        } else if #available(iOS 26.0, *) {
            setToolbarItems([items.selectAll, .flexibleSpace(), items.copy, items.move, items.compress, .flexibleSpace(), items.delete], animated: shouldAnimateToolbar(animated))
        } else {
            setToolbarItems([items.selectAll, .flexibleSpace(), items.copy, .flexibleSpace(), items.move, .flexibleSpace(), items.compress, .flexibleSpace(), items.delete], animated: false)
        }
    }

    /// Keep the buttons alive across count changes so UIKit owns the native
    /// glass group transition instead of receiving a new toolbar for every tap.
    private lazy var selectionToolbar: (selectAll: UIBarButtonItem, copy: UIBarButtonItem, move: UIBarButtonItem, compress: UIBarButtonItem, putBack: UIBarButtonItem, delete: UIBarButtonItem) = {
        let selectAll = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.setAllSelected(self.selectedCount != self.visible.count)
        })
        let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { [weak self] _ in self?.commandCopySelection() })
        copy.accessibilityLabel = String(localized: "Copy")
        let move = UIBarButtonItem(image: UIImage(systemName: "scissors"), primaryAction: UIAction { [weak self] _ in self?.commandMoveSelection() })
        move.accessibilityLabel = String(localized: "Move")
        let compress = UIBarButtonItem(image: UIImage(systemName: "doc.zipper"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            FileActions(presenter: self, directory: self.directory).promptCompress(self.selectedPaths())
        })
        compress.accessibilityLabel = String(localized: "Compress")
        let putBack = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.putBack(self.selectedPaths())
        })
        putBack.accessibilityLabel = String(localized: "Put Back")
        let delete = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in
            self?.commandDeleteSelection()
        })
        delete.tintColor = .systemRed
        if #available(iOS 26.0, *) {
            selectAll.sharesBackground = false
            putBack.sharesBackground = false
            delete.sharesBackground = false
            for (item, identifier) in [(selectAll, "selectAll"), (copy, "copy"), (move, "move"), (compress, "compress"), (putBack, "putBack"), (delete, "delete")] {
                item.identifier = identifier
            }
        }
        return (selectAll, copy, move, compress, putBack, delete)
    }()

    private func shouldAnimateToolbar(_ requested: Bool) -> Bool {
        if #available(iOS 26.0, *) {
            return requested && !UIAccessibility.isReduceMotionEnabled
                && viewIfLoaded?.window != nil
                && navigationController?.topViewController === self
                && navigationController?.transitionCoordinator == nil
        }
        return false
    }

    /// The trailing bar item: Select, New, the running transfers when there
    /// are any, then the folder's own menu. While transfers run, the glyph is
    /// their count — the one place the bar says so without another button.
    private lazy var moreButton: UIBarButtonItem = {
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                guard let self else { done([]); return }
                self.recordDirectoryUse()
                let select = UIAction(
                    title: String(localized: "Select"), image: UIImage(systemName: "checkmark.circle"),
                    attributes: self.visible.isEmpty ? .disabled : []
                ) { [weak self] _ in self?.setEditing(true, animated: true) }
                let running = self.session.operations.operations.filter(\.isRunning).count
                let transfers: [UIMenuElement] = running > 0 ? [UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Tasks"), subtitle: String(localized: "\(running) in progress"),
                        image: UIImage(systemName: "arrow.left.arrow.right")
                    ) { _ in TransfersViewController.presentAsSheet() },
                ])] : []
                let folder: UIMenuElement = self.isTrash ? self.emptyTrashAction() : self.newMenu()
                done([select, folder] + transfers + self.browserMenuElements())
            },
        ]))
        more.accessibilityLabel = String(localized: "More")
        return more
    }()

    private func moreItem() -> UIBarButtonItem {
        let running = session.operations.operations.filter(\.isRunning).count
        moreButton.image = UIImage(systemName: running > 0 ? "\(min(running, 50)).circle" : "ellipsis")
        moreButton.accessibilityValue = running > 0 ? String(localized: "\(running) in progress") : nil
        return moreButton
    }

    @objc private func refreshToolbar() {
        rebuildBrowsingToolbar(animated: false)
    }

    private func rebuildBrowsingToolbar(animated: Bool) {
        guard isViewLoaded, navigationController?.topViewController === self else { return }
        clipboardBar.isHidden = isEditing || isTrash || FileClipboard.shared.isEmpty
        clipboardBar.configure(FileClipboard.shared)
        guard !isEditing else { return }
        navigationItem.rightBarButtonItem = moreItem()

        updatePathBarWidth()
        setToolbarItems(browsingToolbar, animated: shouldAnimateToolbar(animated))
    }

    private lazy var browsingToolbar: [UIBarButtonItem] = {
        let search = UIBarButtonItem(systemItem: .search, primaryAction: UIAction { [weak self] _ in self?.presentSearch() })
        let tabs = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), primaryAction: UIAction { [weak self] _ in
            self?.shell?.presentTabSwitcher()
        })
        tabs.accessibilityLabel = String(localized: "Tabs")
        if #available(iOS 26.0, *) {
            search.sharesBackground = false
            tabs.sharesBackground = false
            for (item, identifier) in [(search, "search"), (tabs, "tabs")] {
                item.identifier = identifier
            }
        }
        return [search, .flexibleSpace(), pathBarItem, .flexibleSpace(), tabs]
    }()

    private func updatePathBarWidth() {
        guard let pathBarWidth else { return }
        // Reserve native control widths, outer margins and inter-group gaps.
        // Measure this content column, never the screen or the split sidebar.
        let available = view.safeAreaLayoutGuide.layoutFrame.width
        let reserved = 2 * FilaUI.minimumTapTarget + 4 * FilaUI.Spacing.large + 2 * FilaUI.Spacing.small
        let width = max(FilaUI.minimumTapTarget, available - reserved)
        if abs((pathBarWidth.layoutConstraints.first?.constant ?? 0) - width) > 0.5 {
            pathBarWidth.update(offset: width)
        }
    }

    func presentClipboard() {
        let controller = ClipboardViewController(clipboard: .shared)
        controller.onReveal = { [weak self] path in self?.shell?.follow(.reveal(path)) }
        presentAsSheet(UINavigationController(rootViewController: controller))
    }

    func select(_ node: FileNode) {
        guard let indexPath = dataSource.indexPath(for: node) else { return }
        setEditing(true, animated: true)
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        updateChrome()
    }

    private func setAllSelected(_ selected: Bool) {
        for row in visible.indices {
            let indexPath = IndexPath(item: row, section: 0)
            if selected {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        updateChrome()
    }

    @objc private func commandCopySelection() { takeSelection(cut: false) }
    @objc private func commandMoveSelection() { takeSelection(cut: true) }
    @objc private func commandDeleteSelection() { delete(selectedPaths()) }

    // MARK: - Navigation

    func path(of node: FileNode) -> String {
        directory == "/" ? "/" + node.name : directory + "/" + node.name
    }

    func selectedPaths() -> [String] {
        (collectionView.indexPathsForSelectedItems ?? [])
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .map(path(of:))
    }

    /// Goes to a directory — and the one rule the whole tab obeys.
    ///
    /// **A tab's navigation stack is the path.** Whatever is on screen, the
    /// stack under it is that directory's chain of ancestors, so Back always
    /// means *one component shallower* and the breadcrumb and Back can never
    /// point in different directions.
    ///
    /// Two gestures, and only two:
    ///
    /// - **Descend.** Tapping a row pushes the child it names. This is the only
    ///   push there is, and it keeps the stack the chain because a child's
    ///   chain is this folder's chain plus one.
    /// - **Jump.** Everything else that names a directory — the breadcrumb, the
    ///   sidebar's places and favorites, *Go to Path*, *Show Original*, a
    ///   `fila://` link — re-roots the tab at that path alone
    ///   (`TabContainerViewController.showRoot`): a replace, not a push, so
    ///   Back at that new root lazily opens its parent. Going to `/etc` from
    ///   `/var/mobile/Documents` must not leave Back walking back out through
    ///   somebody's Documents, and the ancestors are in the breadcrumb.
    ///
    /// Popping is the same thing as jumping to an ancestor, so an ancestor
    /// already on the stack is popped to instead — same destination, with the
    /// animation and the scroll positions that a pop keeps.
    ///
    /// What this replaced pushed *anything* not already on the stack, ancestors
    /// included. After a jump the stack held one directory, so no ancestor was
    /// ever found: from `/var/jb/bin` a tap on `jb` in the breadcrumb put
    /// `/var/jb` on top of it, and Back then walked *deeper*, into `bin`. That
    /// was the whole of "push and pop feel backwards".
    func open(directory path: String) {
        guard let navigation = navigationController else { return }
        if let existing = navigation.viewControllers.last(where: { ($0 as? BrowserViewController)?.directory == path }) {
            navigation.popToViewController(existing, animated: true)
            return
        }
        // A child of this folder is a descent. Anything else is a jump — and
        // the shell owns those, because re-rooting is a tab-wide operation.
        // Without a shell to ask (a browser outside the window), a push is
        // still better than going nowhere.
        if (path as NSString).deletingLastPathComponent != directory, let shell {
            shell.open(path)
            return
        }
        navigation.pushViewController(BrowserViewController(directory: path), animated: true)
    }

    func open(_ node: FileNode) {
        // A trashed item is not somewhere to go or something to read: it is
        // put back, or it is gone. Both are in its menu.
        guard !isTrash else { return }
        if node.isNavigable {
            open(directory: path(of: node))
            return
        }
        recordDirectoryUse()
        Task { await openFile(at: path(of: node), session: session) }
    }

    // MARK: - Keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(title: String(localized: "Refresh"), action: #selector(commandRefresh), input: "r", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Go to Path…"), action: #selector(commandGoToPath), input: "g", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: String(localized: "Search Here…"), action: #selector(commandSearch), input: "f", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: String(localized: "Show Hidden Files"), action: #selector(commandToggleHidden), input: ".", modifierFlags: .command),
        ]
        // Nothing is created in or pasted into the trash, so the keys are not
        // offered there either.
        if !isTrash {
            commands.append(UIKeyCommand(title: String(localized: "New Folder"), action: #selector(commandNewFolder), input: "n", modifierFlags: [.command, .shift]))
            commands.append(UIKeyCommand(title: String(localized: "Paste"), action: #selector(commandPaste), input: "v", modifierFlags: .command))
        }
        return commands
    }

    @objc private func commandRefresh() {
        recordDirectoryUse()
        reload()
    }
    @objc private func commandNewFolder() { promptCreate(.directory) }
    @objc private func commandGoToPath() { promptGoToPath() }
    @objc private func commandSearch() { presentSearch() }
    @objc private func commandPaste() { paste() }

    @objc private func commandToggleHidden() {
        recordDirectoryUse()
        AppPreferences.shared.showsHidden.toggle()
        applySnapshot(animated: true)
    }
}

// MARK: - Collection view

extension BrowserViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != nil
    }

    func collectionView(_: UICollectionView, didBeginMultipleSelectionInteractionAt _: IndexPath) {
        setEditing(true, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing else {
            recordDirectoryUse()
            updateChrome()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return }
        open(node)
    }

    func collectionView(_: UICollectionView, didDeselectItemAt _: IndexPath) {
        if isEditing { updateChrome() }
    }

    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let path = path(of: node)
        let presentation = node.kind == .directory ? appFolders[node.name] : nil
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            presentation.map { AppFolderPreviewViewController(path: path, presentation: $0) }
        }) { [weak self] _ in
            self?.contextMenu(for: node)
        }
    }

    func collectionView(
        _: UICollectionView,
        willDisplayContextMenu _: UIContextMenuConfiguration,
        animator _: UIContextMenuInteractionAnimating?
    ) {
        recordDirectoryUse()
    }

    func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let preview = animator.previewViewController as? AppFolderPreviewViewController else { return }
        animator.addCompletion { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil,
                  self.navigationController?.topViewController === self else { return }
            self.open(directory: preview.path)
        }
    }
}

// MARK: - Drag and drop

extension BrowserViewController: UICollectionViewDragDelegate {
    func collectionView(_: UICollectionView, itemsForBeginning _: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        // A trashed item leaves the trash by Put Back, which knows where it
        // belongs; a drag would carry its origin note along as junk.
        guard !isTrash, let node = dataSource.itemIdentifier(for: indexPath) else { return [] }
        recordDirectoryUse()
        let path = path(of: node)
        let item = UIDragItem(itemProvider: NSItemProvider(object: path as NSString))
        // The local object is what a drop inside the app actually acts on: only
        // this process can open these paths, so nothing useful crosses the app
        // boundary and there is no point promising it.
        item.localObject = path
        return [item]
    }
}

extension BrowserViewController: UICollectionViewDropDelegate {
    func collectionView(
        _: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath indexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .cancel) }
        // Nothing enters the trash but a delete: a dropped item would have no
        // origin to be put back to.
        guard !isTrash else { return UICollectionViewDropProposal(operation: .forbidden) }
        // The same rule the drop applies, shown while the finger is still
        // down: a selection dragged around its own folder, or onto itself,
        // has nowhere to go, and the badge must say so rather than promise a
        // copy that the drop then silently declines.
        let sources = session.items.compactMap { $0.localObject as? String }
        guard !droppable(sources, into: dropTarget(at: indexPath)).isEmpty else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .copy, intent: .insertIntoDestinationIndexPath)
    }

    func collectionView(_: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let sources = coordinator.items.compactMap { $0.dragItem.localObject as? String }
        let target = dropTarget(at: coordinator.destinationIndexPath)
        let moved = droppable(sources, into: target)
        guard !moved.isEmpty else { return }
        recordDirectoryUse()
        promptDrop(sources: moved, target: target)
    }

    /// The folder under the pointer, or this one.
    private func dropTarget(at indexPath: IndexPath?) -> String {
        if let indexPath, let node = dataSource.itemIdentifier(for: indexPath), node.isNavigable { return path(of: node) }
        return directory
    }

    /// Per item, not for the whole drop: dragging a folder together with
    /// three files onto that folder is a real request for the three, and
    /// dropping the rest of a selection must not be cancelled by the one
    /// item that happens to be the destination.
    private func droppable(_ sources: [String], into target: String) -> [String] {
        sources.filter { $0 != target && ($0 as NSString).deletingLastPathComponent != target }
    }
}
