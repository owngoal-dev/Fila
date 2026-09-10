import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaLog
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
///
/// The listing's lifecycle — pages streaming into place, a refresh that
/// keeps its rows until the replacement is complete, one subscription to
/// the directory's changes, a reload held while a menu closes — is
/// `BackendListViewController`'s. What is here is what a directory of files
/// adds to it: the layout preference, the cells, the application
/// decorations, the volume footer, selection and the file actions.
final class FileBrowserViewController: BackendListViewController<FileNode>, TabContentDecorationSource {
    let directory: String

    let session = FileSession.shared

    /// The trash itself. Its rows are put back or emptied, never opened,
    /// created or pasted into. Computed, not stored: a tab restored at launch
    /// exists before the handshake does.
    var isTrash: Bool {
        FileActions.isTrash(directory)
    }

    /// Application names and artwork for the directories on screen, from
    /// the applications capability; empty without it. Display only: every
    /// operation keeps the entry's real name.
    var appFolders: [String: FolderDecoration] = [:]
    private var volume: VolumeInfo?

    override var maximumItemCount: Int { DirectoryReader.maximumEntryCount }
    override var traceName: String { directory }

    private let clipboardBar = ClipboardBarView()
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
        if directory == "/" {
            return String(localized: "Root")
        }
        if isTrash {
            return String(localized: "Trash")
        }
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
        if let restoredScrollOffset {
            return restoredScrollOffset
        }
        return isViewLoaded ? Double(collectionView.contentOffset.y) : 0
    }

    /// `select` is the name of an entry to highlight once it arrives — how
    /// `fila://reveal` lands on the right row. It is a name and not an index
    /// because the listing streams in pages, so the row does not exist yet when
    /// this controller is built, and it may never exist at all.
    init(directory: String, select: String? = nil) {
        self.directory = directory
        pendingSelection = select
        super.init()
        navigationItem.title = folderTitle
        configureNavigationItem()
        buildRegistrations()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderTitle
        buildHierarchy()
        // Made here, outside any provider closure — UIKit refuses a
        // registration created inside one — and only here, because the
        // provider is its one consumer.
        let footer = UICollectionView.SupplementaryRegistration<BrowserFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            guard let self else { return }
            footerView = view
            view.label.text = footerText
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged(_:)),
            name: .filaPreferencesChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshTaskIcon),
            name: .filaOperationsChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshClipboardBar),
            name: .filaClipboardChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: nil
        )
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateChrome()
        // Initialize the shared operation observer when a browser first appears.
        _ = session.operations
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreScrollOffsetIfArrived()
        session.setLastDirectory(directory)
    }

    override func changes() async throws -> AsyncThrowingStream<Void, Error>? {
        let service = try await session.local.fileService()
        guard let location = session.local.servicePath(forAbsolute: directory) else { return nil }
        return try await service.changes(in: location)
    }

    /// Only explicit use records a directory; appearing or dwelling never does.
    /// Rows already received count even while a large listing is still streaming.
    func recordDirectoryUse() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self,
              loadFailure == nil, !isLoading || !items.isEmpty else { return }
        session.noteVisit(directory: directory)
    }

    @objc private func sceneDidEnterBackground(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        recordDirectoryUse()
    }


    override func setEditing(_ editing: Bool, animated: Bool) {
        let modeChanged = editing != isEditing
        if editing, modeChanged {
            recordDirectoryUse()
        }
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        view.setNeedsLayout()
        // Edit mode borrows the left slot for Cancel. A split view puts its
        // own items there, so what was there is put back rather than cleared.
        if editing, borrowedLeftItems == nil {
            borrowedLeftItems = navigationItem.leftBarButtonItems ?? []
        }
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
        if relayout {
            applyLayoutPreference()
        } else {
            applySnapshot(animated: true)
        }
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

    // MARK: - Decoration

    /// App artwork for the crumbs that are app bundles or containers, by
    /// crumb target, once the lookup has answered.
    private var crumbArtwork: [String: UIImage] = [:]

    /// The device or the root, then every folder down to this one; a crumb
    /// opens its folder the way a row does — a child descends, anything
    /// else jumps.
    func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        PathBarView.localCrumbs(for: directory).map { crumb in
            guard let icon = crumbArtwork[crumb.target] else { return crumb }
            return PathBarView.Crumb(title: crumb.title, target: crumb.target, icon: icon)
        }
    }

    func tabContent(_: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb) {
        open(directory: crumb.target)
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        // An app bundle or container wears its app's icon, the same as its
        // row does; the lookup is async, so the folder stands in first.
        Task { [weak self, directory] in
            guard let applications = SystemCapabilities.applications,
                  let artwork = SystemCapabilities.applicationArtwork else { return }
            let decoration = await applications.decorationLookup()
            var found: [String: UIImage] = [:]
            for crumb in PathBarView.localCrumbs(for: directory) {
                guard let identifier = decoration(crumb.target)?.applicationIdentifier,
                      let icon = await artwork.icon(for: identifier) else { continue }
                found[crumb.target] = icon
            }
            guard let self, !found.isEmpty else { return }
            crumbArtwork = found
            reloadDecoration()
        }

        collectionView.do {
            $0.delegate = self
            $0.dragDelegate = self
            $0.dropDelegate = self
            $0.dragInteractionEnabled = true
            $0.allowsMultipleSelectionDuringEditing = true
        }

        clipboardBar.onShow = { [weak self] in self?.presentClipboard() }
        clipboardBar.onPaste = { [weak self] in self?.paste() }
        clipboardBar.onClear = { FileClipboard.shared.clear() }

        view.addSubview(clipboardBar)
        clipboardBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func configureNavigationItem() {
        trailingNavigationItems = [moreItem()]
        wantsSearchButton = true
    }

    /// The bottom bar's Search: the search screen for this folder.
    override func search() {
        presentSearch()
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

    override func makeLayout() -> UICollectionViewLayout {
        switch session.layout(for: directory) {
        case .list:
            let configuration = UICollectionLayoutListConfiguration(appearance: .plain).with {
                // A list section draws a background decoration *over* the
                // collection view's `backgroundView` — which is where the
                // empty/loading panel lives. Clearing it is what keeps "Reading
                // this folder…" visible; the cells carry their own background.
                $0.backgroundColor = .clear
                $0.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    guard let self, let node = dataSource.itemIdentifier(for: indexPath) else { return nil }
                    let title = isTrash ? String(localized: "Delete Permanently") : deleteTitle
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
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalHeight(1)
                ))
                let height = 84 + UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(height)
                    ),
                    subitem: item,
                    count: columns
                )
                group.interItemSpacing = .fixed(FilaUI.Spacing.small)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = FilaUI.Spacing.small
                section.contentInsets = .init(
                    top: FilaUI.Spacing.small,
                    leading: FilaUI.Spacing.medium,
                    bottom: FilaUI.Spacing.small,
                    trailing: FilaUI.Spacing.medium
                )
                section.boundarySupplementaryItems = [Self.footerItem()]
                return section
            }
        }
    }

    private var listCell: UICollectionView.CellRegistration<IconRowCell, FileNode>!
    private var gridCell: UICollectionView.CellRegistration<BrowserGridCell, FileNode>!

    /// Made at construction, long before the first dequeue: UIKit refuses a
    /// registration created inside the cell provider, and a lazy one would
    /// be created exactly there.
    private func buildRegistrations() {
        listCell = UICollectionView.CellRegistration<IconRowCell, FileNode> { [weak self] cell, _, node in
            guard let self else { return }
            cell.configure(node, decoration: appFolders[node.name])
            cell.showThumbnail(for: path(of: node), node: node, session: session)
            if !isTrash {
                cell.showProperties { [weak self] in
                    guard let self else { return }
                    FileActions(presenter: self, directory: directory).showProperties(path(of: node))
                }
            }
        }
        gridCell = UICollectionView.CellRegistration<BrowserGridCell, FileNode> { [weak self] cell, _, node in
            guard let self else { return }
            cell.configure(
                node: node,
                path: path(of: node),
                session: session,
                decoration: appFolders[node.name]
            )
        }
    }

    override func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: FileNode) -> UICollectionViewCell {
        switch session.layout(for: directory) {
        case .list:
            collectionView.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: item)
        case .grid:
            collectionView.dequeueConfiguredReusableCell(using: gridCell, for: indexPath, item: item)
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
        redraw()
        updateChrome()
    }

    /// What the list says about itself when it has no rows to show.
    ///
    /// Five endings, one of which is not an ending at all — and before this
    /// they were the same blank rectangle. The order is the order the facts
    /// override each other in: a refusal outranks a wait, a wait outranks
    /// anything about the contents, and "empty" is only true once the listing
    /// has actually finished saying so.
    override var statusContent: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        if let loadFailure {
            let listingFailure = loadFailure as? FilaFailure
            // The trash is made by the first delete, so a missing one is not
            // a broken folder: say what it is for, and offer to make it now.
            if isTrash, let listingFailure, listingFailure.code == .notFound || listingFailure.systemError == ENOENT {
                return .message(
                    symbol: "trash",
                    artwork: "trash-empty-large",
                    title: String(localized: "No Trash Yet"),
                    detail: String(localized: "Deleted items are moved here so they can be put back."),
                    button: String(localized: "Create Trash")
                )
            }
            return .message(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Unable to Read Folder"),
                detail: listingFailure.map(FailureText.summary) ?? loadFailure.localizedDescription
            )
        }
        // No detail: the daemon may still be launching, and there is nothing
        // here a user could act on — the same reason the connecting panel
        // offers nothing but the word.
        if isLoading {
            return .loading(String(localized: "Reading Folder…"))
        }
        if !items.isEmpty {
            return .message(
                symbol: "eye.slash",
                title: String(localized: "Only Hidden Items"),
                detail: String(localized: "Turn on Show Hidden Files to see them.")
            )
        }
        if isTrash {
            return .message(
                symbol: "trash",
                artwork: "trash-empty-large",
                title: String(localized: "Trash Is Empty"),
                detail: String(localized: "Deleted items are moved here so they can be put back.")
            )
        }
        return .message(symbol: "folder", title: String(localized: "Folder Is Empty"))
    }

    override func statusAction() {
        createTrash()
    }

    /// The trash, made on request the way the first delete would make it: a
    /// directory of the backend's own, 0700.
    private func createTrash() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.perform { link in
                    try await link.create(.directory, at: self.directory)
                    try await link.setAttributes(AttributeChange(mode: 0o700), at: self.directory)
                }
                reload()
            } catch let failure as FilaFailure {
                self.report(failure)
            } catch {}
        }
    }

    // MARK: - Loading

    /// The directory's pages, pulled: the next backend request starts only
    /// when the list asks for the next batch, so a slow screen never queues
    /// pages it has not drawn. The stream owns the iterator, and dropping it
    /// — a listing cut short at the cap — closes the directory.
    override func load() -> AsyncThrowingStream<[FileNode], Error> {
        let pages = DirectoryReader.pages(in: directory, session: session).makeAsyncIterator()
        return AsyncThrowingStream { try await pages.next() }
    }

    override func willStartInitialLoad() {
        appFolders = [:]
    }

    override func loadDidFail(_ error: Error, hadRows: Bool) {
        // Everything under `load()` throws a `FilaFailure`; the other arm is
        // there so a new error type is logged rather than swallowed.
        let failure = error as? FilaFailure
        FilaLog.log(
            failure.map { FilaLog.level(for: $0.code) } ?? .error,
            "listing \(directory) \(failure.map(FilaLog.describe) ?? String(describing: error))"
        )
        // With rows already listed it is a refresh that went wrong halfway,
        // which nothing on screen would show; with none the panel says it.
        if hadRows, let failure {
            report(failure)
        }
    }

    override func loadDidComplete(received: Int, elapsed: TimeInterval, failed: Bool) async {
        // What the user is looking at, and how long it took to get there.
        // Verbose, because it is one line per folder opened and browsing is
        // what this app mostly does — but it is also the first thing anyone
        // asks about a listing that came back short or slow, so it carries
        // the count and the milliseconds.
        if !failed {
            FilaLog.verbose(
                "listed \(directory): \(received) entr(ies)"
                    + (isTruncated ? " (truncated)" : "")
                    + " in \(Int(elapsed * 1000))ms"
            )
        }
        decoratedWithApplications = SystemCapabilities.showsApplications
        // The volume behind the footer, on its own task rather than a child
        // of this one: a listing abandoned mid-flight must not wait on that
        // round trip, and its answer is about this browser's directory
        // whenever it lands.
        Task { [weak self] in await self?.loadVolume() }
        let appFolders = await SystemCapabilities.applications?.decorations(
            in: directory,
            entries: items.map { (name: $0.name, isDirectory: $0.kind == .directory) }
        ) ?? [:]
        guard !Task.isCancelled else { return }
        let refreshAppFolders = !self.appFolders.isEmpty || !appFolders.isEmpty
        self.appFolders = appFolders
        if refreshAppFolders {
            await reconfigureVisibleItems()
        }
    }

    private func loadVolume() async {
        let volume = try? await session.perform(retryOnDisconnect: true) { try await $0.volumeInfo(for: directory) }
        guard !Task.isCancelled else { return }
        self.volume = volume
        updateFooter()
    }

    // MARK: - Snapshot

    /// Scroll a revealed entry into view and select it, once the page carrying
    /// it has landed. Hidden entries are a real case here: a link can name a
    /// dotfile the browser is currently filtering out, and revealing it means
    /// showing it, not silently doing nothing.
    private func revealPendingSelectionIfArrived() {
        guard let name = pendingSelection else { return }
        guard let index = visible.firstIndex(where: { $0.name == name }) else {
            if !session.showsHidden, items.contains(where: { $0.name == name }) {
                session.setShowsHidden(true)
                applySnapshot(animated: false)
            }
            return
        }
        pendingSelection = nil
        let path = IndexPath(item: index, section: 0)
        collectionView.selectItem(at: path, animated: viewIfLoaded?.window != nil, scrollPosition: .centeredVertically)
    }

    /// Puts a restored tab back where it was, once there is enough listed to
    /// scroll. Tried again on every page for the same reason the reveal is: the
    /// listing streams, and a folder that is two pages tall has nowhere to go
    /// while only the first has landed.
    private func restoreScrollOffsetIfArrived() {
        guard viewIfLoaded?.window != nil, collectionView.bounds.height > 0,
              let offset = restoredScrollOffset, !visible.isEmpty else { return }
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

    override func snapshotDidApply() {
        revealPendingSelectionIfArrived()
        restoreScrollOffsetIfArrived()
        // Every page of a long listing lands here, so outside edit mode this
        // only refreshes the footer — rebuilding the whole toolbar per page
        // would be work nobody sees.
        updateFooter()
        if isEditing {
            updateChrome()
        }
    }

    override func arrange(_ nodes: [FileNode]) -> [FileNode] {
        // Deduplicated by name: pages are read from a directory that is live,
        // and one name arriving twice would put two rows with the same identity
        // into the snapshot, which is a crash rather than a glitch.
        var seen = Set<String>()
        var items = nodes.filter { seen.insert($0.name).inserted }
        if !session.showsHidden {
            items.removeAll(where: \.isHidden)
        }
        return items.sorted(by: precedes)
    }

    /// Directories first regardless of direction — reversing that puts the way
    /// out of a folder at the bottom of a hundred thousand files.
    private func precedes(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isNavigable != rhs.isNavigable {
            return lhs.isNavigable
        }
        let order: ComparisonResult = switch session.sortKey {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .date: compare(lhs.modified, rhs.modified)
        case .size: compare(lhs.size, rhs.size)
        case .kind: FilePresentation.sortKind(for: lhs).compare(FilePresentation.sortKind(for: rhs))
        }
        guard order != .orderedSame else {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return session.sortAscending ? order == .orderedAscending : order == .orderedDescending
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
        if isTruncated {
            parts.append(String(localized: "Not all items shown"))
        }
        if let volume {
            let free = FilePresentation.byteLabel(volume.availableByteCount)
            let total = FilePresentation.byteLabel(volume.totalByteCount)
            parts.append(String(localized: "\(free) free of \(total)"))
            // Last, so it sits at the right end of the line: nothing in this
            // folder can be changed, and the daemon's root does not help.
            if volume.isReadOnly {
                parts.append(String(localized: "Read Only"))
            }
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

    private var selectedCount: Int {
        collectionView.indexPathsForSelectedItems?.count ?? 0
    }

    /// What was in the navigation item's left slot before edit mode borrowed it.
    private var borrowedLeftItems: [UIBarButtonItem]?

    /// Selection actions borrow the left item and replace the normal toolbar.
    func updateChrome(animated: Bool = false) {
        guard isViewLoaded, navigationController?.topViewController === self else { return }
        navigationController?.setNavigationBarHidden(false, animated: false)
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
            trailingNavigationItems = [moreItem()]
            setToolbarOverride(nil, animated: animated)
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
        trailingNavigationItems = []

        let items = selectionToolbar
        let allSelected = count == visible.count && !visible.isEmpty
        items.selectAll.image = UIImage(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
        items.selectAll.accessibilityLabel = allSelected
            ? String(localized: "Deselect All")
            : String(localized: "Select All")
        items.selectAll.isEnabled = !visible.isEmpty
        items.delete.image = UIImage(systemName: "trash")
        items.delete.accessibilityLabel = isTrash ? String(localized: "Delete Permanently") : deleteTitle
        for item in [items.copy, items.move, items.compress, items.putBack, items.delete] {
            item.isEnabled = count > 0
        }

        // A count update changes the existing controls without replacing the
        // toolbar, including when select(_:) follows entry into selection mode.
        guard toolbarOverride?.first !== items.selectAll else { return }
        if isTrash {
            // Two verbs in the trash: back where it came from, or gone for good.
            setToolbarOverride(
                [items.selectAll, .flexibleSpace(), items.putBack, .flexibleSpace(), items.delete],
                animated: false
            )
        } else if #available(iOS 26.0, *) {
            setToolbarOverride(
                [
                    items.selectAll,
                    .flexibleSpace(),
                    items.copy,
                    items.move,
                    items.compress,
                    .flexibleSpace(),
                    items.delete,
                ],
                animated: animated
            )
        } else {
            setToolbarOverride(
                [
                    items.selectAll,
                    .flexibleSpace(),
                    items.copy,
                    .flexibleSpace(),
                    items.move,
                    .flexibleSpace(),
                    items.compress,
                    .flexibleSpace(),
                    items.delete,
                ],
                animated: false
            )
        }
    }

    /// Keep the buttons alive across count changes so UIKit owns the native
    /// glass group transition instead of receiving a new toolbar for every tap.
    private lazy var selectionToolbar: (
        selectAll: UIBarButtonItem,
        copy: UIBarButtonItem,
        move: UIBarButtonItem,
        compress: UIBarButtonItem,
        putBack: UIBarButtonItem,
        delete: UIBarButtonItem
    ) = {
        let selectAll = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.circle"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                setAllSelected(selectedCount != visible.count)
            }
        )
        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in self?.takeSelection(cut: false) }
        )
        copy.accessibilityLabel = String(localized: "Copy")
        let move = UIBarButtonItem(
            image: UIImage(systemName: "scissors"),
            primaryAction: UIAction { [weak self] _ in self?.takeSelection(cut: true) }
        )
        move.accessibilityLabel = String(localized: "Move")
        let compress = UIBarButtonItem(
            image: UIImage(systemName: "doc.zipper"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                FileActions(presenter: self, directory: directory).promptCompress(selectedPaths())
            }
        )
        compress.accessibilityLabel = String(localized: "Compress")
        let putBack = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.putBack(selectedPaths())
            }
        )
        putBack.accessibilityLabel = String(localized: "Put Back")
        let delete = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.delete(selectedPaths())
        })
        delete.tintColor = .systemRed
        if #available(iOS 26.0, *) {
            selectAll.sharesBackground = false
            putBack.sharesBackground = false
            delete.sharesBackground = false
            for (item, identifier) in [
                (selectAll, "selectAll"),
                (copy, "copy"),
                (move, "move"),
                (compress, "compress"),
                (putBack, "putBack"),
                (delete, "delete"),
            ] {
                item.identifier = identifier
            }
        }
        return (selectAll, copy, move, compress, putBack, delete)
    }()


    /// The trailing bar item groups creation, display preferences, and navigation.
    /// While transfers run, the glyph is
    /// their count — the one place the bar says so without another button.
    private lazy var moreButton: UIBarButtonItem = {
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                guard let self else { done([]); return }
                recordDirectoryUse()
                let select = UIAction(
                    title: String(localized: "Select"),
                    image: UIImage(systemName: "checkmark.circle"),
                    attributes: visible.isEmpty ? .disabled : []
                ) { [weak self] _ in self?.setEditing(true, animated: true) }
                let running = session.operations.operations.filter(\.isRunning).count
                let transfers: [UIMenuElement] = running > 0 ? [UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Tasks"),
                        subtitle: String(localized: "\(running) in progress"),
                        image: UIImage(systemName: "tray.and.arrow.down.fill")
                    ) { _ in TransfersViewController.presentAsSheet() },
                ])] : []
                let folder: UIMenuElement = isTrash ? emptyTrashAction() : newMenu()
                done(browserMenuElements(folderAction: folder, selectAction: select) + transfers)
            },
        ]))
        more.accessibilityLabel = String(localized: "More")
        return more
    }()

    private var displayedTaskCount: Int?

    @objc private func refreshTaskIcon() {
        _ = moreItem()
    }

    private func moreItem() -> UIBarButtonItem {
        let running = session.operations.operations.filter(\.isRunning).count
        guard displayedTaskCount != running else { return moreButton }
        if displayedTaskCount.map({ min($0, 50) }) != min(running, 50) {
            moreButton.image = UIImage(systemName: running > 0 ? "\(min(running, 50)).circle" : "ellipsis")
        }
        displayedTaskCount = running
        moreButton.accessibilityValue = running > 0 ? String(localized: "\(running) in progress") : nil
        return moreButton
    }

    @objc private func refreshClipboardBar() {
        guard isViewLoaded else { return }
        clipboardBar.isHidden = isEditing || isTrash || FileClipboard.shared.isEmpty
        clipboardBar.configure(FileClipboard.shared)
    }

    func presentClipboard() {
        let controller = ClipboardViewController(clipboard: .shared)
        controller.onReveal = { [weak self] item in
            guard let self else { return }
            if item.backend == session.local.id {
                shell?.follow(.reveal(session.local.absolutePath(item.path)))
            } else if let parent = item.path.parent {
                // A share's browser has no selection to land on; its folder
                // is the nearest thing to revealing the entry.
                BackendScreens.shell?.open(BackendLocation(backend: item.backend, item: parent.description))
            }
        }
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

    func selectedPaths() -> [String] {
        (collectionView.indexPathsForSelectedItems ?? [])
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .map(path(of:))
    }

    // MARK: - Keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(
                title: String(localized: "Refresh"),
                action: #selector(commandRefresh),
                input: "r",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Go to Path…"),
                action: #selector(commandGoToPath),
                input: "g",
                modifierFlags: [.command, .shift]
            ),
            UIKeyCommand(
                title: String(localized: "Search Here…"),
                action: #selector(commandSearch),
                input: "f",
                modifierFlags: [.command, .shift]
            ),
            UIKeyCommand(
                title: String(localized: "Show Hidden Files"),
                action: #selector(commandToggleHidden),
                input: ".",
                modifierFlags: .command
            ),
        ]
        // Nothing is created in or pasted into the trash, so the keys are not
        // offered there either.
        if !isTrash {
            commands.append(UIKeyCommand(
                title: String(localized: "New Folder"),
                action: #selector(commandNewFolder),
                input: "n",
                modifierFlags: [.command, .shift]
            ))
            commands.append(UIKeyCommand(
                title: String(localized: "Paste"),
                action: #selector(commandPaste),
                input: "v",
                modifierFlags: .command
            ))
        }
        return commands
    }

    override func refreshRequested() {
        commandRefresh()
    }

    @objc private func commandRefresh() {
        recordDirectoryUse()
        reload()
    }

    @objc private func commandNewFolder() {
        promptCreate(.directory)
    }

    @objc private func commandGoToPath() {
        promptGoToPath()
    }

    @objc private func commandSearch() {
        presentSearch()
    }

    @objc private func commandPaste() {
        paste()
    }

    @objc private func commandToggleHidden() {
        recordDirectoryUse()
        session.setShowsHidden(!session.showsHidden)
        applySnapshot(animated: true)
    }
}
