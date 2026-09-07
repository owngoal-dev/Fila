import FilaProtocol
import SnapKit
import Then
import UIKit

/// Places, favorite paths, and app-wide destinations.
final class SidebarViewController: UIViewController {
    private enum Section: Int {
        case places
        case favorites
        case mounts
        case recents

        var title: String? {
            switch self {
            case .places: String(localized: "Places")
            case .favorites: String(localized: "Favorites")
            case .mounts: String(localized: "Mount Points")
            case .recents: String(localized: "Recents")
            }
        }
    }

    private enum Item: Hashable {
        case header(Section)
        case place(SidebarLocation)
        case favorite(String)
        case apps
        case music
        case recent(String)
        case mount(String)
    }

    private let session = FileSession.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// Only the current eight rows' presentation; thumbnail reuse stays in ThumbnailCache.
    private var recentItems: [String: (image: UIImage?, name: String?)] = [:]
    private var recentsDecoratedWithApplications = SystemCapabilities.showsApplications
    private var recentImageTask: Task<Void, Never>?
    private var rebuildGeneration = UUID()
    private var isApplyingSnapshot = false
    private var openTask: Task<Void, Never>?
    private var mounts: [MountPoint] = []
    private var mountTask: Task<Void, Never>?
    /// Whether the trash holds anything, so its row can show a full or empty
    /// bin. Asked of the backend rather than the app's own filesystem: the
    /// trash is root-owned 0700 on a daemon. A missing or unreadable trash is
    /// an empty one.
    private var trashHasItems = false
    private var trashProbe: Task<Void, Never>?
    private var columnToggle: UIBarButtonItem?
    private lazy var settingsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.shell?.presentSettings()
        })
        item.accessibilityLabel = String(localized: "Settings")
        return item
    }()
    private lazy var doneItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        item.accessibilityLabel = String(localized: "Close")
        return item
    }()
    private lazy var tasksItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.left.arrow.right"), primaryAction: UIAction { [weak self] _ in
            self?.presentTasks()
        })
        item.accessibilityLabel = String(localized: "Tasks")
        return item
    }()

    func setColumnToggle(_ item: UIBarButtonItem?, animated: Bool = false) {
        guard columnToggle !== item else { return }
        columnToggle = item
        updateBarButtons(animated: animated)
    }

    private func updateBarButtons(animated: Bool = false) {
        let running = session.operations.operations.filter(\.isRunning).count
        tasksItem.accessibilityValue = running > 0 ? String(localized: "\(running) in progress") : nil
        if navigationItem.leftBarButtonItem !== settingsItem { navigationItem.leftBarButtonItem = settingsItem }
        let dismissItem = presentingViewController != nil ? doneItem : nil
        let items = [columnToggle ?? dismissItem, running > 0 ? tasksItem : nil].compactMap { $0 }
        if (navigationItem.rightBarButtonItems ?? []) != items { navigationItem.setRightBarButtonItems(items, animated: animated) }
    }

    deinit {
        recentImageTask?.cancel()
        openTask?.cancel()
        mountTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Places")
        view.backgroundColor = .systemBackground
        // Nothing on an iPad, where this is a column; a Close button on a phone,
        // where it is a sheet.
        installModalDoneButton()

        let layout = UICollectionViewCompositionalLayout { [weak self] section, environment in
            guard let self, let sections = self.dataSource?.snapshot().sectionIdentifiers,
                  sections.indices.contains(section) else { return nil }
            let identifier = sections[section]
            let configuration = UICollectionLayoutListConfiguration(appearance: environment.traitCollection.horizontalSizeClass == .regular ? .sidebar : .insetGrouped).with {
                $0.headerMode = identifier.title == nil ? .none : .firstItemInSection
                $0.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    self?.swipeActions(at: indexPath)
                }
            }
            let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if section == 0 { layout.contentInsets.top = 0 }
            return layout
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        buildDataSource()
        for name in [Notification.Name.filaSidebarChanged, .filaPreferencesChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(probeTrash), name: .filaJobFinished, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(loadMounts), name: UIApplication.didBecomeActiveNotification, object: nil)
        rebuild()
        Task { [weak self] in
            await FileSession.shared.ready()
            self?.rebuild()
            self?.probeTrash()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadRecentImages()
        probeTrash()
        loadMounts()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        recentImageTask?.cancel()
        trashProbe?.cancel()
        mountTask?.cancel()
        openTask?.cancel()
    }

    @objc private func loadMounts() {
        guard viewIfLoaded?.window != nil else { return }
        mountTask?.cancel()
        mountTask = Task { [weak self, session] in
            let hello = await session.ready()
            guard !Task.isCancelled, hello.backend != .local(reach: .container) else { return }
            do {
                let mounts = try await session.perform(retryOnDisconnect: true) { try await $0.mountPoints() }
                guard let self, !Task.isCancelled else { return }
                self.mounts = mounts
                self.rebuild()
            } catch {
                // The shortcut section can be retried by reopening Places;
                // an older daemon may not have the mount-table request yet.
            }
        }
    }

    /// One page is enough: the question is whether there is anything at all.
    @objc private func probeTrash() {
        guard let backend = session.hello?.backend else { return }
        let path = SidebarLocation.trashDirectory(backend: backend)
        trashProbe?.cancel()
        trashProbe = Task { [weak self, session] in
            let page = try? await session.perform(retryOnDisconnect: true) { try await $0.list(directory: path, cursor: 0) }
            guard let self, !Task.isCancelled else { return }
            let hasItems = page?.entries.isEmpty == false
            guard hasItems != self.trashHasItems else { return }
            self.trashHasItems = hasItems
            for item in self.dataSource.snapshot().itemIdentifiers {
                guard case let .place(place) = item, FileActions.isTrash(place.path),
                      let index = self.dataSource.indexPath(for: item),
                      let cell = self.collectionView.cellForItem(at: index) as? IconRowCell else { continue }
                self.configure(cell, for: item)
            }
        }
    }

    // MARK: - Rows

    private func buildDataSource() {
        let row = UICollectionView.CellRegistration<IconRowCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listSidebarCell().updated(for: state)
                background.backgroundColorTransformer = nil
                background.backgroundColor = state.isSelected || state.isHighlighted
                    ? UIColor.systemGray.withAlphaComponent(0.1) : .secondarySystemGroupedBackground
                cell.backgroundConfiguration = background
            }
        }
        let header = UICollectionView.CellRegistration<UICollectionViewListCell, Section> { cell, _, section in
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = section.title
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .header))]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, item in
            if case let .header(section) = item {
                return collection.dequeueConfiguredReusableCell(using: header, for: indexPath, item: section)
            }
            return collection.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
    }

    private func configure(_ cell: IconRowCell, for item: Item) {
        var name: String
        var detail: String?
        var image: UIImage?
        var color: UIColor = .label
        switch item {
        case .header: return
        case let .place(place):
            name = place.title
            switch place.icon {
            case let .artwork(artwork):
                let artwork = FileActions.isTrash(place.path) && !trashHasItems ? "trash-empty" : artwork
                image = UIImage(named: "FileIcons/\(artwork)")?.withRenderingMode(.alwaysOriginal)
            case let .symbol(symbol): image = UIImage(systemName: symbol)
            }
        case let .favorite(path), let .recent(path):
            name = path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent
            detail = path
            // Until `details(of:)` answers, draw what the path was when it was
            // recorded: a file keeps its type artwork instead of a folder.
            let kind: FileKind = AppPreferences.shared.recentFiles.contains(path) ? .regular : .directory
            image = recentItems[path]?.image ?? FilePresentation.image(kind: kind, name: name)
            if let displayName = recentItems[path]?.name {
                name = displayName
                color = .systemBrown
            }
        case let .mount(path):
            guard let mount = mounts.first(where: { $0.path == path }) else { return }
            name = path == "/" ? String(localized: "Root") : (path as NSString).lastPathComponent
            detail = mount.isReadOnly ? [path, String(localized: "Read Only")].joined(separator: " · ") : path
            image = UIImage(named: "FileIcons/drive-internal")?.withRenderingMode(.alwaysOriginal)
        case .apps:
            name = String(localized: "Applications")
            image = UIImage(named: "FileIcons/application")?.withRenderingMode(.alwaysOriginal)
        case .music:
            name = String(localized: "Music")
            image = UIImage(named: "FileIcons/music")?.withRenderingMode(.alwaysOriginal)
        }
        cell.configure(name: name, detail: detail, image: image, nameColor: color, tintColor: .tintColor)
        if case .favorite = item { cell.showFavoriteBadge() }
    }

    // MARK: - Snapshot

    private var presets: [Item] {
        var items = SidebarLocation.jumpList(backend: session.hello?.backend).map { ($0.position, Item.place($0)) }
        if SystemCapabilities.showsApplications { items.append((.applications, .apps)) }
        if FileManager.default.fileExists(atPath: "/var/mobile/Media/iTunes_Control") { items.append((.music, .music)) }
        let available = Dictionary(uniqueKeysWithValues: items)
        let preferences = AppPreferences.shared
        return preferences.presetOrder.filter { preferences.isPresetEnabled($0) }.compactMap { available[$0] }
    }

    @objc private func rebuild() {
        let generation = UUID()
        rebuildGeneration = generation
        recentImageTask?.cancel()
        // Coalesce notifications while UIKit finishes the current animation.
        // Its completion will restart from the newest preferences.
        guard !isApplyingSnapshot else { return }
        isApplyingSnapshot = true
        let preferences = AppPreferences.shared
        updateBarButtons()
        // Capped: the sidebar is a shortcut list, not a history browser, and a
        // hundred rows of recents pushes everything else off the screen.
        let recents = Array(preferences.recents.prefix(8))
        // Cached names and icons were looked up under the old Applications
        // setting; a container decorated as "Safari" must not stay that way
        // after the setting that allowed it is off.
        if recentsDecoratedWithApplications != SystemCapabilities.showsApplications {
            recentsDecoratedWithApplications = SystemCapabilities.showsApplications
            recentItems = [:]
        }
        recentItems = recentItems.filter { recents.contains($0.key) || preferences.favorites.contains($0.key) }
        let sections: [(Section, [Item])] = [
            (.places, presets),
            (.favorites, preferences.favorites.map(Item.favorite)),
            (.mounts, mounts.map { Item.mount($0.path) }),
            (.recents, recents.map(Item.recent)),
        ].filter { !$0.1.isEmpty }
        let previous = dataSource.snapshot()
        let collapsed = Set(previous.sectionIdentifiers.filter { section in
            let outline = dataSource.snapshot(for: section)
            let header = Item.header(section)
            return section.title != nil && outline.items.contains(header) && !outline.isExpanded(header)
        })
        var snapshot = previous
        snapshot.deleteSections(previous.sectionIdentifiers.filter { old in !sections.contains { $0.0 == old } })
        for (index, entry) in sections.enumerated() where !snapshot.sectionIdentifiers.contains(entry.0) {
            if index < snapshot.sectionIdentifiers.count {
                snapshot.insertSections([entry.0], beforeSection: snapshot.sectionIdentifiers[index])
            } else {
                snapshot.appendSections([entry.0])
            }
        }
        let animate = view.window != nil && !previous.sectionIdentifiers.isEmpty && !UIAccessibility.isReduceMotionEnabled
        let outlines = sections.map { section, items in
            var outline = NSDiffableDataSourceSectionSnapshot<Item>()
            if section.title != nil {
                let header = Item.header(section)
                outline.append([header])
                outline.append(items, to: header)
                if !collapsed.contains(section) { outline.expand([header]) }
            } else {
                outline.append(items)
            }
            return (section, outline)
        }
        if snapshot.sectionIdentifiers != previous.sectionIdentifiers {
            dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.applyOutlines(outlines, at: 0, generation: generation, animated: animate)
                }
            }
        } else {
            applyOutlines(outlines, at: 0, generation: generation, animated: animate)
        }
    }

    /// Each completion belongs to the rebuild that scheduled it. A newer
    /// snapshot takes over without letting an old animation refresh new rows.
    private func applyOutlines(
        _ outlines: [(Section, NSDiffableDataSourceSectionSnapshot<Item>)],
        at start: Int,
        generation: UUID,
        animated: Bool
    ) {
        guard rebuildGeneration == generation else {
            isApplyingSnapshot = false
            rebuild()
            return
        }
        for index in start ..< outlines.count {
            let (section, outline) = outlines[index]
            guard dataSource.snapshot(for: section).items != outline.items else { continue }
            dataSource.apply(outline, to: section, animatingDifferences: animated) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.applyOutlines(outlines, at: index + 1, generation: generation, animated: animated)
                }
            }
            return
        }
        isApplyingSnapshot = false
        refreshVisibleRows()
        loadRecentImages()
    }

    private func refreshVisibleRows() {
        // Re-applying the flat `snapshot()` here would replace the section
        // snapshots with their visible rows only, losing collapsed children and
        // the disclosure state. Rows on screen are refreshed by hand; the rest
        // configure when they are dequeued.
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) as? IconRowCell else { continue }
            configure(cell, for: item)
        }
    }

    private func loadRecentImages() {
        recentImageTask?.cancel()
        guard !isApplyingSnapshot, viewIfLoaded?.window != nil else { return }
        let paths = dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
            switch item {
            case let .recent(path), let .favorite(path):
                return recentItems[path] == nil ? path : nil
            default: return nil
            }
        }
        guard !paths.isEmpty else { return }
        recentImageTask = Task { [weak self, session] in
            let apps = await InstalledAppCatalog.load(session: session)
            // One bounded sequence, never one task per cell or per scroll event.
            var loaded = Set<String>()
            for path in paths where loaded.insert(path).inserted {
                guard !Task.isCancelled else { return }
                guard let details = try? await session.perform(retryOnDisconnect: true, { try await $0.details(of: path) }) else { continue }
                guard !Task.isCancelled else { return }
                let node = details.node
                let presentation = AppFolderDisplay.presentation(for: path, apps: apps)
                var image = FilePresentation.image(for: node)
                if let identifier = presentation?.applicationIdentifier {
                    image = await AppFolderDisplay.icon(for: identifier)
                } else if node.kind == .regular, FilePresentation.format(of: node) == .image,
                   let thumbnail = await ThumbnailCache.shared.thumbnail(for: path, node: node, session: session) {
                    image = thumbnail
                }
                guard let self, !Task.isCancelled else { return }
                let items = [Item.recent(path), Item.favorite(path)]
                guard items.contains(where: self.dataSource.snapshot().itemIdentifiers.contains) else { continue }
                self.recentItems[path] = (image, presentation?.name)
                // Keep section outlines intact. Offscreen cells pick up the
                // cached artwork when configured; refresh matching visible rows.
                for item in items {
                    guard let index = self.dataSource.indexPath(for: item),
                          let cell = self.collectionView.cellForItem(at: index) as? IconRowCell else { continue }
                    self.configure(cell, for: item)
                }
            }
        }
    }

    private func openRecent(_ path: String) {
        openTask = Task { [weak self, session] in
            do {
                let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
                guard let self, !Task.isCancelled, self.viewIfLoaded?.window != nil,
                      self.navigationController?.topViewController === self, let shell = self.shell else { return }
                if details.node.isNavigable {
                    shell.open(path)
                } else {
                    AppPreferences.shared.noteVisit(path, isDirectory: false)
                    await shell.openFile(details, session: session)
                }
            } catch let failure as FilaFailure {
                guard let self, !Task.isCancelled, self.viewIfLoaded?.window != nil,
                      self.navigationController?.topViewController === self else { return }
                // A recent that no longer exists is not worth an alert, and
                // not worth keeping: the entry goes, the sidebar rebuilds.
                if failure.code == .notFound || failure.systemError == ENOENT {
                    AppPreferences.shared.forgetRecent(path)
                    Toast.show(String(localized: "Removed from Recents"))
                    return
                }
                self.report(failure)
            } catch {}
        }
    }

    private func presentTasks() {
        guard presentedViewController == nil else { return }
        let tasks = TransfersViewController(center: session.operations)
        let navigation = UINavigationController(rootViewController: tasks).then {
            $0.modalPresentationStyle = traitCollection.horizontalSizeClass == .regular ? .popover : .pageSheet
            $0.preferredContentSize = CGSize(width: 420, height: 520)
        }
        tasks.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak navigation] _ in
                navigation?.dismiss(animated: true)
            }
        )
        tasks.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
        navigation.popoverPresentationController?.barButtonItem = tasksItem
        present(navigation, animated: true)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case let .favorite(path):
            let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { _, _, done in
                AppPreferences.shared.toggleFavorite(path)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [remove])
        default:
            return nil
        }
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .header = item {
            // The outline disclosure already toggled the section; collapsing
            // one must not cancel an open that is still waiting on the daemon.
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }
        openTask?.cancel()
        switch item {
        case .header:
            break
        case let .place(place):
            open(place.path)
        case let .favorite(path), let .mount(path):
            open(path)
        case let .recent(path):
            openRecent(path)
        case .apps:
            collectionView.deselectItem(at: indexPath, animated: true)
            shell?.replace(AppListViewController())
        case .music:
            collectionView.deselectItem(at: indexPath, animated: true)
            shell?.replace(MusicLibraryViewController())
        }
    }

    /// `shell` rather than `splitViewController`: on a phone this list is a
    /// sheet the shell presented, and a presented screen has no split view
    /// above it to ask.
    private func open(_ path: String) {
        openTask = Task { [weak self] in
            await FileSession.shared.ready()
            guard !Task.isCancelled else { return }
            self?.shell?.open(path)
        }
    }
}
