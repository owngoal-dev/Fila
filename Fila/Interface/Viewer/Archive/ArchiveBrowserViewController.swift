import AlertController
import FilaBackendUI
import FilaClient
import FilaFormats
import FilaLog
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Lists an archive and extracts a selection out of it.
///
/// Nothing is unpacked to look at it: the list is one pass over the headers, so
/// a 2 GB `.ipa` lists without a byte of its content being decompressed.
///
/// Extraction submits a job to the shared operation center. The daemon runs
/// the fixed archive helper; the local backend runs ArchiveJob in-process.
/// Both use the same path guard and atomic publication, and no archive bytes
/// enter the daemon. Member indices retain the original archive order even
/// when a root-directory marker is hidden from the list.
final class ArchiveBrowserViewController: TabContentViewController {
    private let title_: String
    /// What an `.extract` job reads: the file itself, or the staged member of
    /// a nested archive.
    private let archivePath: String
    private let link: any LocalFileAccess
    /// A fresh read descriptor on the archive, closed by whoever asked for it.
    ///
    /// libarchive is forward-only, so listing and extracting are two passes and
    /// each one needs its own. The container above already holds a descriptor on
    /// this file, but it is private to it — one extra `open(2)` per screen is
    /// cheaper than reaching for it.
    private let openArchive: @Sendable () async throws -> Int32
    /// Where "Extract" starts from — the directory the archive itself lives in.
    private let destinationHint: String
    /// Set only for a nested archive: the member pulled out into the app's own
    /// container, removed when this screen goes.
    private let staged: URL?

    /// One listed member, and the identity the snapshot sorts on.
    ///
    /// The index is the member's position in the archive's own order, and it is
    /// here because the pathname is not an identity: an archive may legitimately
    /// carry the same name twice — a tar that recorded a file before and after
    /// an edit does — and two equal identifiers in one snapshot is a crash, not
    /// a duplicate row.
    private struct Row: Hashable {
        var index: Int
        var entry: ArchiveEntry
    }

    private enum Item: Hashable {
        case directory(String)
        case member(Row)
    }

    private let directory: String
    private var members: [Row]?
    /// Virtual folders still act on their archive file. A separately staged
    /// nested archive has no such owner and must not act on the outer file.
    private weak var fileActionsOwner: ViewerContainerViewController?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let progress = StagingView()
    /// The one archive pass in flight, if any.
    ///
    /// Every one of them is `Task.detached`, because libarchive's calls block
    /// and none of them may run on the main actor. Detached also means the task
    /// does not inherit cancellation from anywhere — which is the point: this
    /// handle is the only thing that cancels it, and the read loop's progress
    /// handler is what notices, between blocks.
    private var work: Task<Void, Never>?

    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()

    /// `file` is the descriptor the container opened to detect the format with.
    /// It stays the container's; see `openArchive`.
    convenience init(details: FileDetails, file _: DescriptorFile, link: any LocalFileAccess) {
        let path = details.path
        self.init(
            title: (path as NSString).lastPathComponent,
            archivePath: path,
            link: link,
            destinationHint: (path as NSString).deletingLastPathComponent,
            staged: nil,
            openArchive: { try await link.open(path, flags: O_RDONLY) }
        )
    }

    private init(
        title: String,
        archivePath: String,
        link: any LocalFileAccess,
        destinationHint: String,
        staged: URL?,
        directory: String = "",
        members: [Row]? = nil,
        fileActionsOwner: ViewerContainerViewController? = nil,
        openArchive: @escaping @Sendable () async throws -> Int32
    ) {
        title_ = title
        self.archivePath = archivePath
        self.link = link
        self.destinationHint = destinationHint
        self.staged = staged
        self.openArchive = openArchive
        self.directory = directory
        self.members = members
        self.fileActionsOwner = fileActionsOwner
        super.init(nibName: nil, bundle: nil)
        self.title = directory.isEmpty ? title : String(directory.split(separator: "/").last ?? "")
        refreshActions()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        // libarchive's read loop is synchronous between blocks, so cancelling is
        // a flag the pump checks — see the progress handler in `extract`.
        work?.cancel()
        if let staged {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = UICollectionLayoutListConfiguration(appearance: .plain).with {
            $0.backgroundColor = .clear
            $0.footerMode = .supplementary
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        ).then {
            $0.delegate = self
            $0.allowsMultipleSelectionDuringEditing = true
        }
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.textProperties.numberOfLines = 2
            let canOpen: Bool
            switch item {
            case let .directory(path):
                content.text = String(path.split(separator: "/").last ?? "")
                content.secondaryText = String(localized: "Folder")
                content.image = FilePresentation.image(kind: .directory, name: path)
                canOpen = true
            case let .member(row):
                content.text = row.entry.relativePath == nil ? row.entry.declaredPath : row.entry.name
                content.secondaryText = row.entry.byteCount.map(FilePresentation.byteLabel) ?? "—"
                content.image = FilePresentation.image(kind: row.entry.kind, name: row.entry.name)
                canOpen = Self.isNested(row.entry)
            }
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.maximumSize = CGSize(width: FilaUI.IconSize.file, height: FilaUI.IconSize.file)
            content.imageProperties.reservedLayoutSize = content.imageProperties.maximumSize
            cell.contentConfiguration = content
            cell.accessories = canOpen
                ? [.multiselect(), .disclosureIndicator(displayed: .whenNotEditing)]
                : [.multiselect()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, row in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        let footer = UICollectionView.SupplementaryRegistration<BrowserFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            let count = self?.members?.count ?? 0
            footer.label.text = count == ArchiveReader.maximumEntryCount
                ? String(format: String(localized: "Showing the first %lld items."), Int64(count)) : nil
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }

        progress.isHidden = true
        view.addSubview(progress)
        progress.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.readableContentGuide)
            make.centerY.equalToSuperview()
        }

        refreshActions()
        if members != nil {
            rebuild()
        } else {
            collectionView.showStatus(.loading(String(localized: "Opening…")))
            load()
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        if !editing {
            for path in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: path, animated: false)
            }
        }
        refreshActions()
    }

    private func refreshActions() {
        let hasMembers = (members ?? []).contains { !$0.entry.isRootDirectory && !$0.entry.isFinderMetadata }
        let canSelect = hasMembers && (!isViewLoaded || progress.isHidden)
        let canExtract = canSelect && (!isEditing || !(collectionView.indexPathsForSelectedItems ?? []).isEmpty)
        let select = UIAction(
            title: isEditing ? String(localized: "Done") : String(localized: "Select"),
            image: UIImage(systemName: "checklist"),
            attributes: canSelect ? [] : .disabled
        ) { [weak self] _ in
            guard let self else { return }
            setEditing(!isEditing, animated: true)
        }
        let extractTitle = isEditing
            ? String(localized: "Extract Selection")
            : members?.count == ArchiveReader.maximumEntryCount
            ? String(localized: "Extract Listed Items")
            : String(localized: "Extract All")
        let extract = UIAction(
            title: extractTitle,
            image: UIImage(systemName: "archivebox"),
            attributes: canExtract ? [] : .disabled
        ) { [weak self] _ in
            guard let self else { return }
            self.extract(chosenRows)
        }
        let extractTo = UIAction(
            title: String(localized: "Extract To…"),
            image: UIImage(systemName: "folder"),
            attributes: canExtract ? [] : .disabled
        ) { [weak self] _ in
            guard let self else { return }
            self.extract(chosenRows, choosingDestination: true)
        }
        if let container = parent as? ViewerContainerViewController {
            trailingNavigationItems = []
            fileActionsOwner = container
            container.childMenuElements = [select, extract, extractTo]
            container.refreshBarItems()
        } else {
            menuItem.menu = UIMenu(
                children: FilaMenu.groups([select, extract, extractTo])
                    + (fileActionsOwner?.fileMenuElements(presenting: self) ?? [])
                    + [settingsMenuElement]
            )
            trailingNavigationItems = [menuItem]
        }
    }

    private func rebuild() {
        var folders = Set<String>()
        var items: [Item] = []
        let prefix = directory.isEmpty ? "" : directory + "/"
        for row in members ?? [] {
            guard !row.entry.isRootDirectory, !row.entry.isFinderMetadata else { continue }
            guard let relative = row.entry.relativePath else {
                if directory.isEmpty {
                    items.append(.member(row))
                }
                continue
            }
            guard relative.hasPrefix(prefix), relative != directory else { continue }
            let remaining = relative.dropFirst(prefix.count)
            if let slash = remaining.firstIndex(of: "/") {
                folders.insert(prefix + remaining[..<slash])
            } else if row.entry.isDirectory {
                folders.insert(relative)
            } else {
                items.append(.member(row))
            }
        }
        items.insert(contentsOf: folders.sorted().map(Item.directory), at: 0)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.showStatus(
            items.isEmpty ? .message(symbol: "archivebox", title: String(localized: "No Items")) : nil
        )
        refreshActions()
    }

    private func entries(for items: [Item]) -> [Row] {
        var indices = Set<Int>()
        var directories = Set<String>()
        for item in items {
            switch item {
            case let .member(row): indices.insert(row.index)
            case let .directory(path): directories.insert(path)
            }
        }
        return (members ?? []).filter { row in
            if indices.contains(row.index) {
                return true
            }
            guard !directories.isEmpty, let relative = row.entry.relativePath else { return false }
            var path = ""
            for component in relative.split(separator: "/") {
                path = path.isEmpty ? String(component) : path + "/" + component
                if directories.contains(path) {
                    return true
                }
            }
            return false
        }
    }

    private func load() {
        let openArchive = openArchive
        let name = title_
        work?.cancel()
        work = Task.detached { [weak self] in
            let result: Result<[ArchiveEntry], Error>
            do {
                let descriptor = try await openArchive()
                defer { close(descriptor) }
                // A compressed tar has to be decompressed to be walked, so a
                // listing of a large one is real work. The handler is how
                // leaving the screen stops it.
                result = Result {
                    let reader = try DescriptorReader(descriptor: descriptor)
                    try PreviewLimits.validate(byteCount: reader.byteCount, format: .archive)
                    return try ArchiveReader.list(descriptor: descriptor, name: name) { _, _ in !Task.isCancelled }
                }
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.show(result) }
        }
    }

    private func show(_ result: Result<[ArchiveEntry], Error>) {
        switch result {
        case let .success(entries):
            FilaLog.info("archive \(title_) listed: \(entries.count) member(s)")
            // Numbered in the archive's own order, then shown in name order.
            // The number is the identity and never changes; the sort is only
            // what the reader sees.
            members = entries.enumerated()
                .map { Row(index: $0.offset, entry: $0.element) }
                .sorted { $0.entry.declaredPath < $1.entry.declaredPath }
            rebuild()
        case let .failure(error):
            // libarchive's own refusal — an unsupported filter, a truncated
            // file, a password. The screen shows one sentence; this keeps the
            // rest.
            FilaLog.warning("archive \(title_) could not be listed: \(error)")
            let label = UILabel()
            label.text = FailureMessage.text(for: error)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            collectionView.backgroundView = label
        }
    }

    // MARK: - Extraction

    /// The shared extraction, which asks its questions on whichever screen is
    /// on top: the viewer that embeds this one, or this one when pushed.
    private var fileActions: FileActions {
        FileActions(presenter: parent as? ViewerContainerViewController ?? self, directory: destinationHint)
    }

    /// The selection while selecting, otherwise everything this screen lists.
    private var chosenRows: [Row] {
        guard isEditing else {
            return directory.isEmpty ? members ?? [] : entries(for: [.directory(directory)])
        }
        return entries(for: (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            dataSource.itemIdentifier(for: $0)
        })
    }

    /// Beside the archive, or wherever the user picks.
    private func extract(_ rows: [Row], choosingDestination: Bool = false) {
        let rows = rows.filter { !$0.entry.isRootDirectory && !$0.entry.isFinderMetadata }
        guard !rows.isEmpty else { return }
        guard choosingDestination else { return extract(rows, into: destinationHint) }
        let form = SaveDestinationViewController(
            directory: URL(fileURLWithPath: destinationHint, isDirectory: true),
            message: String(
                format: String(localized: "%lld items will be extracted here without replacing existing items."),
                Int64(rows.count)
            ),
            link: link
        ) { [weak self] destination in
            self?.extract(rows, into: destination.path)
        }
        presentAsSheet(UINavigationController(rootViewController: form))
    }

    /// Matched by position in the archive, never by name: a name is not an
    /// identity — an archive may carry the same one twice — and the name rides
    /// along only so the job can notice the archive changing underneath the
    /// two passes. See `ArchiveJob` for the ordering and the link checks.
    private func extract(_ rows: [Row], into destination: String) {
        setEditing(false, animated: true)
        fileActions.extract(
            archivePath,
            members: rows.map { ArchiveSelection(index: Int64($0.index), declaredPath: $0.entry.declaredPath) },
            into: destination,
            estimate: ArchiveSpaceEstimate(entries: rows.map(\.entry)),
            encrypted: rows.contains(where: \.entry.isEncrypted)
        )
    }
}

extension ArchiveBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing else { return refreshActions() }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .directory(path):
            pushDetail(ArchiveBrowserViewController(
                title: title_,
                archivePath: archivePath,
                link: link,
                destinationHint: destinationHint,
                staged: nil,
                directory: path,
                members: members,
                fileActionsOwner: fileActionsOwner,
                openArchive: openArchive
            ))
        case let .member(row):
            if Self.isNested(row.entry) {
                descend(into: row)
            } else if row.entry.kind == .regular {
                // A link or a device member carries no bytes to show.
                preview(row)
            }
        }
    }

    func collectionView(_: UICollectionView, didDeselectItemAt _: IndexPath) {
        refreshActions()
    }

    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions = [
                UIAction(title: String(localized: "Extract"), image: UIImage(systemName: "archivebox")) { _ in
                    self.extract(self.entries(for: [item]))
                },
                UIAction(title: String(localized: "Extract To…"), image: UIImage(systemName: "folder")) { _ in
                    self.extract(self.entries(for: [item]), choosingDestination: true)
                },
            ]
            if case let .member(row) = item {
                if Self.isNested(row.entry) {
                    actions.insert(UIAction(title: String(localized: "Open"), image: UIImage(systemName: "arrow.right")) { _ in
                        self.descend(into: row)
                    }, at: 0)
                } else if row.entry.kind == .regular {
                    actions.insert(UIAction(title: String(localized: "Preview"), image: UIImage(systemName: "eye")) { _ in
                        self.preview(row)
                    }, at: 0)
                }
            }
            return UIMenu(children: actions)
        }
    }

    /// A member worth descending into. Decided by the name alone, because the
    /// bytes are a whole pass away and the answer is only used to draw an
    /// accessory: `control.tar.gz` and `data.tar.xz` inside a `.deb`, a `.zip`
    /// inside a `.zip`.
    private static func isNested(_ entry: ArchiveEntry) -> Bool {
        entry.kind == .regular && FileFormat.detect(head: Data(), name: entry.name) == .archive
    }

    /// A `.deb` is an `ar` holding a compressed tar, and the thing anyone wants
    /// out of one is a layer down. The child owns the staged directory.
    private func descend(into row: Row) {
        stage(row) { [self] staged in
            pushDetail(ArchiveBrowserViewController(
                title: row.entry.name,
                archivePath: staged.path,
                link: link,
                destinationHint: destinationHint,
                staged: staged,
                openArchive: {
                    let descriptor = open(staged.path, O_RDONLY)
                    guard descriptor >= 0 else { throw ViewerFailure.readFailed(errno) }
                    return descriptor
                }
            ))
        }
    }

    /// The member in the app's own viewer, the way a snapshot of a remote file
    /// is shown; the viewer's going removes the staged directory.
    private func preview(_ row: Row) {
        stage(row) { [self] staged in
            let directory = staged.deletingLastPathComponent()
            guard let shell = BackendScreens.shell else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            // From the screen the stack holds — the viewer container around
            // this browser, or this browser pushed a layer down — or an open
            // that pushed nothing is taken for the viewer it opened.
            shell.preview(staged, title: row.entry.name, from: navigationController?.topViewController ?? self) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Pulls one member out into a fresh directory in the app's workspace,
    /// under the name the archive gives it so a viewer detects it as it would
    /// on disk, then hands it to `use`, which owns the directory from then on.
    /// Staged rather than held in memory — it can be a hundred megabytes — and
    /// nothing is handed over once this screen is no longer on top.
    private func stage(_ row: Row, password: String? = nil, then use: @escaping @MainActor (URL) -> Void) {
        if row.entry.isEncrypted, password == nil {
            return fileActions.promptArchivePassword { [weak self] password in
                self?.stage(row, password: password, then: use)
            }
        }
        collectionView.isHidden = true
        progress.isHidden = false
        progress.showStatus(String(localized: "Opening…"))
        refreshActions()
        let openArchive = openArchive
        let name = title_
        work?.cancel()
        work = Task.detached { [weak self] in
            do {
                let staging = try await FileSession.shared.makeTemporaryDirectory()
                var handedOff = false
                defer {
                    if !handedOff {
                        try? FileManager.default.removeItem(at: staging)
                    }
                }
                let staged = try await Self.write(row, from: openArchive, archiveName: name, password: password, into: staging)
                guard !Task.isCancelled else { return }
                handedOff = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return false }
                    endStaging()
                    guard let navigation = navigationController,
                          navigation.topViewController === self || navigation.topViewController === parent else { return false }
                    use(staged)
                    return true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.endStaging()
                    self?.report(error)
                }
            }
        }
    }

    private func endStaging() {
        progress.isHidden = true
        collectionView.isHidden = false
        refreshActions()
    }

    /// Walks to the member by its position — never its name, see `Row` — and
    /// writes it into `directory`. libarchive blocks, so this runs detached.
    private nonisolated static func write(
        _ row: Row,
        from openArchive: @Sendable () async throws -> Int32,
        archiveName: String,
        password: String?,
        into directory: URL
    ) async throws -> URL {
        let descriptor = try await openArchive()
        defer { close(descriptor) }
        let reader = try ArchiveReader(descriptor: descriptor, name: archiveName, password: password)
        var index = -1
        while let candidate = try reader.next() {
            guard !Task.isCancelled else { throw CancellationError() }
            index += 1
            guard index == row.index else { continue }
            guard candidate.declaredPath == row.entry.declaredPath else {
                throw ViewerFailure.unsupportedContent(
                    String(localized: "The archive changed while it was open. Open it again.")
                )
            }
            // The name the archive declared is untrusted; `..` would climb out.
            let target = directory.appendingPathComponent(ArchivePath.validated(row.entry.name) ?? "item")
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw ViewerFailure.writeFailed(EACCES)
            }
            let output = open(target.path, O_WRONLY | O_TRUNC)
            guard output >= 0 else { throw ViewerFailure.writeFailed(errno) }
            defer { close(output) }
            try reader.read(into: output, maximumByteCount: ViewerLimits.containerCopyByteCount) { _, _ in
                !Task.isCancelled
            }
            return target
        }
        throw ViewerFailure.unsupportedContent(
            String(localized: "This item is no longer in the archive. Open it again.")
        )
    }

    private func report(_ error: Error) {
        presentMessage(String(localized: "Unable to Open This File"), message: FailureMessage.text(for: error))
    }
}
