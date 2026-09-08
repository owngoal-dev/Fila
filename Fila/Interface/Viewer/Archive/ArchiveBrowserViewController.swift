import AlertController
import FilaClient
import FilaFormats
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
final class ArchiveBrowserViewController: UIViewController {
    private let title_: String
    /// What an `.extract` job reads: the file itself, or the staged member of
    /// a nested archive.
    private let archivePath: String
    private let link: DaemonLink
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
    convenience init(details: FileDetails, file _: DescriptorFile, link: DaemonLink) {
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
        link: DaemonLink,
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
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        refreshActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        // libarchive's read loop is synchronous between blocks, so cancelling is
        // a flag the pump checks — see the progress handler in `extract`.
        work?.cancel()
        if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
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
                content.image = FilePresentation.image(kind: row.entry.kind, name: row.entry.name, mode: row.entry.mode)
                canOpen = Self.isNested(row.entry)
            }
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
            cell.contentConfiguration = content
            cell.accessories = canOpen ? [.multiselect(), .disclosureIndicator(displayed: .whenNotEditing)] : [.multiselect()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, row in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        let footer = UICollectionView.SupplementaryRegistration<BrowserFooterView>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] footer, _, _ in
            let count = self?.members?.count ?? 0
            footer.label.text = count == ArchiveReader.maximumEntryCount
                ? String(format: String(localized: "Showing the first %lld entries."), Int64(count)) : nil
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
        if members != nil { rebuild() } else {
            collectionView.showStatus(.loading(String(localized: "Opening…")))
            load()
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        if !editing {
            for path in collectionView.indexPathsForSelectedItems ?? [] { collectionView.deselectItem(at: path, animated: false) }
        }
        refreshActions()
    }

    private func refreshActions() {
        let hasMembers = (members ?? []).contains { !$0.entry.isRootDirectory }
        let canSelect = hasMembers && (!isViewLoaded || progress.isHidden)
        let canExtract = canSelect && (!isEditing || !(collectionView.indexPathsForSelectedItems ?? []).isEmpty)
        let select = UIAction(title: isEditing ? String(localized: "Done") : String(localized: "Select"), image: UIImage(systemName: "checklist"), attributes: canSelect ? [] : .disabled) { [weak self] _ in
            guard let self else { return }
            self.setEditing(!self.isEditing, animated: true)
        }
        let extractTitle = isEditing ? String(localized: "Extract Selection")
            : members?.count == ArchiveReader.maximumEntryCount ? String(localized: "Extract Listed Entries") : String(localized: "Extract All")
        let extract = UIAction(title: extractTitle, image: UIImage(systemName: "archivebox"), attributes: canExtract ? [] : .disabled) { [weak self] _ in
            self?.promptForDestination()
        }
        if let container = parent as? ViewerContainerViewController {
            navigationItem.rightBarButtonItem = nil
            fileActionsOwner = container
            container.childMenuElements = [select, extract]
            container.refreshBarItems()
        } else {
            let tabs = UIAction(title: String(localized: "Tabs"), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                self?.shell?.presentTabSwitcher()
            }
            menuItem.menu = UIMenu(children: FilaMenu.groups([select, extract]) + (fileActionsOwner?.fileMenuElements(presenting: self) ?? []) + FilaMenu.groups([tabs]))
            navigationItem.rightBarButtonItem = menuItem
        }
    }

    private func rebuild() {
        var folders = Set<String>()
        var items: [Item] = []
        let prefix = directory.isEmpty ? "" : directory + "/"
        for row in members ?? [] {
            guard !row.entry.isRootDirectory else { continue }
            guard let relative = row.entry.relativePath else {
                if directory.isEmpty { items.append(.member(row)) }
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
        collectionView.showStatus(items.isEmpty ? .message(symbol: "archivebox", title: String(localized: "No Entries")) : nil)
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
            if indices.contains(row.index) { return true }
            guard !directories.isEmpty, let relative = row.entry.relativePath else { return false }
            var path = ""
            for component in relative.split(separator: "/") {
                path = path.isEmpty ? String(component) : path + "/" + component
                if directories.contains(path) { return true }
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
            // Numbered in the archive's own order, then shown in name order.
            // The number is the identity and never changes; the sort is only
            // what the reader sees.
            members = entries.enumerated()
                .map { Row(index: $0.offset, entry: $0.element) }
                .sorted { $0.entry.declaredPath < $1.entry.declaredPath }
            rebuild()
        case let .failure(error):
            let label = UILabel()
            label.text = FailureMessage.text(for: error)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            collectionView.backgroundView = label
        }
    }

    // MARK: - Extraction

    private func promptForDestination() {
        if isEditing {
            let items = (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
            chooseDestination(for: entries(for: items))
        } else {
            chooseDestination(for: directory.isEmpty ? members ?? [] : entries(for: [.directory(directory)]))
        }
    }

    private func chooseDestination(for selected: [Row]) {
        let selected = selected.filter { !$0.entry.isRootDirectory }
        guard !selected.isEmpty else { return }

        let stem = ArchivePath.extractionFolderName(for: title_)
        let form = SaveDestinationViewController(
            directory: URL(fileURLWithPath: destinationHint, isDirectory: true),
            folderName: stem.isEmpty ? "extracted" : stem,
            message: String(format: String(localized: "%lld items will be created in this folder. Replaced items are deleted, not moved to the trash."), Int64(selected.count)),
            link: link
        ) { [weak self] destination in
            self?.extract(selected, to: destination.path)
        }
        presentAsSheet(UINavigationController(rootViewController: form))
    }

    /// An `.extract` job on the daemon — the work runs in `fila-archive`, or
    /// in-process without a daemon — with the screen covered by its progress.
    ///
    /// Matched by position in the archive, never by name: a name is not an
    /// identity — an archive may carry the same one twice — and the name rides
    /// along only so the job can notice the archive changing underneath the
    /// two passes. See `ArchiveJob` for the ordering and the link checks.
    ///
    /// An encrypted member is asked for its password before the job starts;
    /// a wrong one comes back as `.wrongPassword` and is asked again.
    private func extract(_ selection: [Row], to destination: String, password: String? = nil, spaceConfirmed: Bool = false) {
        if password == nil, selection.contains(where: { $0.entry.isEncrypted }) {
            return promptPassword { [weak self] password in self?.extract(selection, to: destination, password: password) }
        }
        setEditing(false, animated: true)
        let request = JobRequest(
            kind: .extract,
            sources: [archivePath],
            destination: destination,
            overwrite: true,
            archive: ArchiveOptions(
                password: password,
                members: selection.map { ArchiveSelection(index: Int64($0.index), declaredPath: $0.entry.declaredPath) }
            )
        )
        let center = FileSession.shared.operations
        Task { [weak self] in
            guard self != nil else { return }
            do {
                if !spaceConfirmed {
                    guard let self else { return }
                    let estimate = ArchiveSpaceEstimate(entries: selection.map(\.entry))
                    // Advisory only. The extraction checks real writes even if
                    // the volume cannot provide an estimate here.
                    if let available = try? await self.availableSpace(at: destination),
                       estimate.needsWarning(availableByteCount: available) {
                        let message = estimate.hasUnknownSize
                            ? String(localized: "The archive does not report all extracted file sizes. There may not be enough space to finish extracting.")
                            : String(
                                format: String(localized: "The extracted files need approximately %1$@, more than %2$@ of the %3$@ available at the destination."),
                                FilePresentation.byteLabel(estimate.byteCount),
                                ArchiveSpaceEstimate.warningFraction.formatted(.percent),
                                FilePresentation.byteLabel(available)
                            )
                        let alert = AlertViewController(title: "Low Storage Space", message: message) { [weak self] context in
                            context.addAction(title: "Close") { context.dispose() }
                            context.addAction(title: "Extract", attribute: .accent) {
                                context.dispose { self?.extract(selection, to: destination, password: password, spaceConfirmed: true) }
                            }
                        }
                        self.present(alert, animated: true)
                        return
                    }
                }
                try Task.checkCancellation()
                let identifier = try await center.startJob(
                    request,
                    kind: .extract,
                    title: OperationCenter.Kind.extract.runningTitle,
                    subtitle: OperationCenter.describe([request.sources[0]], destination: destination)
                ) { [weak self] outcome in
                    guard outcome.code == .wrongPassword else { return }
                    // The cover is still on its way out; give it the beat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.promptPassword { [weak self] password in self?.extract(selection, to: destination, password: password) }
                    }
                }
                guard let self, let operation = center.operation(forJob: identifier) else { return }
                OperationCoverViewController.present(for: operation.id, from: self, center: center)
            } catch {
                self?.report(error)
            }
        }
    }

    /// A new extraction folder does not exist yet. Ask the backend for the
    /// nearest existing ancestor, whose resolved volume will receive it.
    private func availableSpace(at destination: String) async throws -> Int64 {
        guard destination.hasPrefix("/") else { throw FilaFailure(code: .invalidRequest, path: destination) }
        var path = destination
        while true {
            do { return try await link.volumeInfo(for: path).availableByteCount }
            catch let failure as FilaFailure where failure.systemError == ENOENT && path != "/" {
                path = (path as NSString).deletingLastPathComponent
            }
        }
    }

    private func promptPassword(_ handler: @escaping (String) -> Void) {
        let alert = AlertInputViewController(
            title: "Enter Password",
            message: "This archive is encrypted. Enter its password to extract.",
            placeholder: "Password",
            text: "",
            doneButtonText: "Extract"
        ) { password in
            guard !password.isEmpty else { return }
            handler(password)
        }
        present(alert, animated: true)
    }
}

extension ArchiveBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing else { return refreshActions() }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .directory(path):
            navigationController?.pushViewController(
                ArchiveBrowserViewController(
                    title: title_,
                    archivePath: archivePath,
                    link: link,
                    destinationHint: destinationHint,
                    staged: nil,
                    directory: path,
                    members: members,
                    fileActionsOwner: fileActionsOwner,
                    openArchive: openArchive
                ),
                animated: true
            )
        case let .member(row):
            if Self.isNested(row.entry) { descend(into: row) }
            else { chooseDestination(for: [row]) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        refreshActions()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIAction(title: String(localized: "Extract"), image: UIImage(systemName: "archivebox")) { _ in
                self.chooseDestination(for: self.entries(for: [item]))
            }]
            if case let .member(row) = item, Self.isNested(row.entry) {
                actions.insert(UIAction(title: String(localized: "Open"), image: UIImage(systemName: "arrow.right")) { _ in self.descend(into: row) }, at: 0)
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
    /// out of one is a layer down.
    ///
    /// The member is staged in the app's workspace rather than held in memory
    /// — it can be a hundred megabytes — and the child owns its directory.
    private func descend(into row: Row) {
        let entry = row.entry
        collectionView.isHidden = true
        progress.isHidden = false
        progress.showFailure(String(localized: "Opening…"))
        refreshActions()
        let openArchive = openArchive
        let name = title_
        let link = link
        let destinationHint = destinationHint
        work?.cancel()
        work = Task.detached { [weak self] in
            do {
                let staging = try await FileSession.shared.makeTemporaryDirectory()
                let staged = staging.appendingPathComponent("archive")
                var handedOff = false
                defer { if !handedOff { try? FileManager.default.removeItem(at: staging) } }
                try Task.checkCancellation()
                let descriptor = try await openArchive()
                defer { close(descriptor) }
                let reader = try ArchiveReader(descriptor: descriptor, name: name)
                var found = false
                var index = -1
                while !found, let candidate = try reader.next() {
                    guard !Task.isCancelled else { return }
                    index += 1
                    guard index == row.index else { continue }
                    guard candidate.declaredPath == entry.declaredPath else {
                        throw ViewerFailure.unsupportedContent(String(localized: "The archive changed while it was open. Open it again."))
                    }
                    guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
                        throw ViewerFailure.writeFailed(EACCES)
                    }
                    let output = open(staged.path, O_WRONLY | O_TRUNC)
                    guard output >= 0 else { throw ViewerFailure.writeFailed(errno) }
                    defer { close(output) }
                    try reader.read(into: output, maximumByteCount: ViewerLimits.containerCopyByteCount) { _, _ in !Task.isCancelled }
                    found = true
                }
                guard found else {
                    throw ViewerFailure.unsupportedContent(String(localized: "This entry is no longer in the archive. Open it again."))
                }
                guard !Task.isCancelled else { return }
                // The child owns the staged file and removes it when it goes, so
                // it has to be built before the push and cleaned up by hand if
                // there is no navigation controller left to push onto. Building
                // it inside the argument list would skip both when the optional
                // chain short-circuits, and leave the file behind for good.
                handedOff = await MainActor.run { [weak self] () -> Bool in
                    self?.progress.isHidden = true
                    self?.collectionView.isHidden = false
                    self?.refreshActions()
                    guard let self, let navigation = self.navigationController,
                          navigation.topViewController === self || navigation.topViewController === self.parent else { return false }
                    navigation.pushViewController(
                        ArchiveBrowserViewController(
                            title: entry.name,
                            archivePath: staged.path,
                            link: link,
                            destinationHint: destinationHint,
                            staged: staged,
                            openArchive: {
                                let descriptor = open(staged.path, O_RDONLY)
                                guard descriptor >= 0 else { throw ViewerFailure.readFailed(errno) }
                                return descriptor
                            }
                        ),
                        animated: true
                    )
                    return true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.progress.isHidden = true
                    self?.collectionView.isHidden = false
                    self?.refreshActions()
                    self?.report(error)
                }
            }
        }
    }

    private func report(_ error: Error) {
        let alert = AlertViewController(
            title: "Unable to Open This File",
            message: FailureMessage.text(for: error)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }
}
