#if canImport(UIKit)
import Darwin
import FilaBackendKit
import Then
import UIKit

/// A directory on a remote file backend, over the neutral file contract.
///
/// What the local browser is to `LocalFileAccess`, this is to
/// `FileService`: one listing owner on the shared list base, pulled one
/// batch at a time, refreshed on the backend's invalidation hints, with the
/// backend's bookmarks and history. A file opens as a snapshot — a bounded
/// download into an app-owned workspace, shown by the app's own viewer and
/// removed when the viewer lets go — and can be saved into the local
/// filesystem through the app's operation centre. Nothing here writes to
/// the server: mutation through this contract is a later phase.
///
/// Not protocol-specific: the backend is `any FileBackend` and every request
/// is one the contract names. An SMB share and an FTP root would share this
/// screen unchanged.
public final class FileServiceBrowserViewController: BackendListViewController<FileEntry>, TabContentDecorationSource {
    /// A snapshot larger than this is not downloaded for a look: the
    /// workspace is on the device's own storage and a preview is not a
    /// transfer the user asked to keep.
    public static let previewSizeLimit: Int64 = 512 * 1024 * 1024

    public let backend: any FileBackend
    public let path: ServicePath
    private var visitRecorded = false
    private var truncationReported = false
    private var snapshotTask: Task<Void, Never>?
    private let cell = UICollectionView.CellRegistration<BackendRowCell, FileEntry> { cell, _, entry in
        let icon = BackendScreens.shell?.fileIcon(named: entry.name, isDirectory: entry.entersDirectory)
            ?? UIImage(systemName: entry.entersDirectory ? "folder" : "doc")
        cell.configure(name: entry.name, detail: FileServiceBrowserViewController.detail(for: entry), image: icon)
        cell.accessories = entry.entersDirectory ? [.disclosureIndicator()] : []
        cell.contentView.alpha = entry.isHidden ? 0.55 : 1
    }

    /// The package's own catalogue: this target is compiled into
    /// FilaCore, whose bundle has no strings of its own.
    private var bundle: Bundle { .module }

    public init(backend: any FileBackend, path: ServicePath) {
        self.backend = backend
        self.path = path
        super.init()
        title = path.name ?? backend.root.displayName
        trailingNavigationItems = [actionsItem]
    }

    // MARK: - Decoration

    /// The share, then every folder down to this one. The share wears the
    /// picture its sidebar row has; the folders wear the folder icon.
    public func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        let shell = BackendScreens.shell
        var crumbs = [PathBarView.Crumb(
            title: backend.root.displayName,
            target: ServicePath.root.description,
            icon: shell?.rootArtwork(for: backend.root)
        )]
        var prefix = ServicePath.root
        for component in path.components {
            guard let next = try? prefix.appending(component) else { break }
            prefix = next
            crumbs.append(PathBarView.Crumb(
                title: component,
                target: prefix.description,
                icon: shell?.fileIcon(named: component, isDirectory: true)
            ))
        }
        return crumbs
    }

    /// A tapped crumb: back to that folder's screen when it is on this
    /// stack, which it is after a descent; otherwise, after a jump into a
    /// deep folder from the sidebar, forward into a screen for it.
    public func tabContent(_: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb) {
        guard let ancestor = try? ServicePath(crumb.target), let navigation = navigationController else { return }
        let existing = navigation.viewControllers.last { controller in
            guard let browser = controller as? FileServiceBrowserViewController else { return false }
            return browser.backend.id == backend.id && browser.path == ancestor
        }
        if let existing {
            navigation.popToViewController(existing, animated: true)
        } else {
            navigation.pushViewController(FileServiceBrowserViewController(backend: backend, path: ancestor), animated: true)
        }
    }

    deinit {
        snapshotTask?.cancel()
    }

    private lazy var actionsItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.actionElements() ?? []) }])
    ).then {
        $0.accessibilityLabel = String(localized: "Actions", bundle: bundle)
    }

    private func actionElements() -> [UIMenuElement] {
        let favorite = isFavorite
        let toggle = UIAction(
            title: favorite
                ? String(localized: "Remove from Favorites", bundle: bundle)
                : String(localized: "Add to Favorites", bundle: bundle),
            image: UIImage(systemName: favorite ? "star.slash" : "star")
        ) { [weak self] _ in
            guard let self else { return }
            do {
                try backend.setFavorite(path, included: !favorite)
            } catch {
                BackendScreens.shell?.alert(
                    title: String(localized: "Could Not Save Favorite", bundle: bundle),
                    message: BackendScreens.shell?.failureText(for: error) ?? String(describing: error)
                )
            }
        }
        let refresh = UIAction(
            title: String(localized: "Refresh", bundle: bundle),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in
            self?.reload()
        }
        var groups: [UIMenuElement] = [UIMenu(options: .displayInline, children: [toggle])]
        // Paste lands here, through the app's operation centre: the items on
        // the clipboard may be local files or another share's, and the
        // transfer decides how they travel. Offered only while something is
        // held, and disabled while a paste is already under way.
        if let clipboard = BackendScreens.shell?.clipboard {
            let paste = UIAction(
                title: clipboard.isCut
                    ? String(localized: "Move Here (\(clipboard.count) items)", bundle: bundle)
                    : String(localized: "Copy Here (\(clipboard.count) items)", bundle: bundle),
                image: UIImage(systemName: "doc.on.clipboard"),
                attributes: clipboard.isPasting ? .disabled : []
            ) { [weak self] _ in
                guard let self else { return }
                BackendScreens.shell?.paste(into: FileLocation(backend: backend.id, path: path), from: self)
            }
            groups.append(UIMenu(options: .displayInline, children: [paste]))
        }
        groups.append(UIMenu(options: .displayInline, children: [refresh]))
        return groups
    }

    /// The backend's sidebar contribution is its authority on favourites;
    /// this is its latest snapshot, not a second store.
    private var favoritesSnapshot: Set<ServicePath> = []
    private var sidebarTask: Task<Void, Never>?

    private var isFavorite: Bool { favoritesSnapshot.contains(path) }

    override public func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        sidebarTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in backend.sidebarUpdates() {
                guard !Task.isCancelled else { return }
                favoritesSnapshot = Set(snapshot.favorites.compactMap(\.path))
            }
        }
    }

    // MARK: - List hooks

    override public func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: FileEntry) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
    }

    override public func load() -> AsyncThrowingStream<[FileEntry], Error> {
        let backend = backend
        let path = path
        // Nothing of the screen is captured: a listing in flight after a
        // pop must not keep it alive while its cursor is torn down.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let service = try await backend.fileService()
                    for try await batch in try await service.list(path) {
                        try Task.checkCancellation()
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override public func changes() async throws -> AsyncThrowingStream<Void, Error>? {
        let service = try await backend.fileService()
        return try await service.changes(in: path)
    }

    override public func arrange(_ items: [FileEntry]) -> [FileEntry] {
        items.sorted { a, b in
            if a.entersDirectory != b.entersDirectory { return a.entersDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    override public var statusContent: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        if isLoading, items.isEmpty {
            return .loading(String(localized: "Connecting…", bundle: bundle))
        }
        if let loadFailure {
            return .message(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Could Not List Folder", bundle: bundle),
                detail: BackendScreens.shell?.failureText(for: loadFailure) ?? loadFailure.localizedDescription,
                button: String(localized: "Try Again", bundle: bundle)
            )
        }
        return .message(
            symbol: "folder",
            title: String(localized: "Empty Folder", bundle: bundle),
            detail: String(localized: "There is nothing in this folder on the server.", bundle: bundle)
        )
    }

    override public func statusAction() {
        reload()
    }

    override public func loadDidFail(_ error: Error, hadRows: Bool) {
        guard hadRows else { return }
        BackendScreens.shell?.alert(
            title: String(localized: "Could Not Refresh", bundle: bundle),
            message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
        )
    }

    override public func loadDidComplete(received: Int, elapsed: TimeInterval, failed: Bool) async {
        guard !failed else { return }
        if !visitRecorded {
            visitRecorded = true
            try? backend.recordVisit(path)
        }
        if isTruncated, !truncationReported {
            truncationReported = true
            BackendScreens.shell?.toast(String(localized: "Showing the first \(maximumItemCount) items", bundle: bundle))
        }
    }

    // MARK: - Opening

    private func open(_ entry: FileEntry) {
        guard let child = try? path.appending(entry.name) else { return }
        if entry.entersDirectory {
            navigationController?.pushViewController(
                FileServiceBrowserViewController(backend: backend, path: child), animated: true
            )
        } else {
            snapshot(entry, at: child) { [weak self] file, release in
                guard let self else { release(); return }
                BackendScreens.shell?.preview(file, title: entry.name, from: self, released: release)
            }
        }
    }

    /// Downloads `entry` into a fresh workspace, behind the delayed progress
    /// card, and hands the file over with the closure that removes the
    /// workspace. A failed or cancelled download removes it itself and
    /// says why, except a cancellation, which is silent.
    private func snapshot(
        _ entry: FileEntry, at child: ServicePath, then use: @escaping @MainActor (URL, @escaping () -> Void) -> Void
    ) {
        guard let shell = BackendScreens.shell else { return }
        if let size = entry.size, size > Self.previewSizeLimit {
            shell.alert(
                title: String(localized: "File Too Large to Preview", bundle: bundle),
                message: String(
                    localized: "“\(entry.name)” is \(Self.format(size)). Files over \(Self.format(Self.previewSizeLimit)) are not downloaded for a preview.",
                    bundle: bundle
                )
            )
            return
        }
        snapshotTask?.cancel()
        let backend = backend
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let card = shell.progressCard(
                title: String(localized: "Downloading…", bundle: bundle),
                message: String(localized: "Fetching “\(entry.name)” from the server.", bundle: bundle),
                from: self
            )
            var workspace: URL?
            do {
                let directory = try await shell.makeWorkspace()
                workspace = directory
                let target = directory.appendingPathComponent(entry.name)
                let service = try await backend.fileService()
                let descriptor = try Self.openStaging(target)
                do {
                    try await service.copyContents(of: child, to: descriptor) { progress in
                        Task { @MainActor in
                            guard let expected = progress.expected, expected > 0 else { return }
                            card.update(message: String(
                                localized: "\(Self.format(progress.completed)) of \(Self.format(expected))", bundle: self.bundle
                            ))
                        }
                    }
                } catch {
                    close(descriptor)
                    throw error
                }
                close(descriptor)
                try Task.checkCancellation()
                card.dismiss()
                use(target) { try? FileManager.default.removeItem(at: directory) }
            } catch {
                card.dismiss()
                if let workspace { try? FileManager.default.removeItem(at: workspace) }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                shell.alert(
                    title: String(localized: "Could Not Download", bundle: bundle),
                    message: shell.failureText(for: error)
                )
            }
        }
        snapshotTask = task
    }

    /// Saves `entry` into the local filesystem: a snapshot, then the app's
    /// own copy job into the chosen folder, then the workspace goes.
    private func save(_ entry: FileEntry) {
        guard let child = try? path.appending(entry.name), let shell = BackendScreens.shell else { return }
        let picker = shell.saveDestinationPicker(fileName: entry.name) { [weak self] destination in
            guard let self else { return }
            snapshot(entry, at: child) { file, release in
                Task { @MainActor in
                    defer { release() }
                    do {
                        try await shell.copy(file, into: destination.deletingLastPathComponent().path, subtitle: entry.name)
                        shell.toast(String(localized: "Saved “\(entry.name)”", bundle: self.bundle))
                    } catch {
                        shell.alert(
                            title: String(localized: "Could Not Save", bundle: self.bundle),
                            message: shell.failureText(for: error)
                        )
                    }
                }
            }
        }
        shell.presentSheet(picker, from: self)
    }

    private static func openStaging(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StagingError(code: errno, path: url.path) }
        return descriptor
    }

    struct StagingError: Error, LocalizedError {
        let code: Int32
        let path: String
        var errorDescription: String? { "\(path): \(String(cString: strerror(code)))" }
    }

    // MARK: - Wording

    static func detail(for entry: FileEntry) -> String? {
        var pieces: [String] = []
        if let size = entry.size, !entry.entersDirectory {
            pieces.append(format(size))
        }
        if let modified = entry.modified {
            pieces.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension FileServiceBrowserViewController: UICollectionViewDelegate {
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        open(entry)
    }

    public func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return nil }
        holdsReloads = true
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var children: [UIMenuElement] = []
            if entry.entersDirectory {
                let child = try? path.appending(entry.name)
                let favorite = child.map { self.favoritesSnapshot.contains($0) } ?? false
                children.append(UIAction(
                    title: favorite
                        ? String(localized: "Remove from Favorites", bundle: bundle)
                        : String(localized: "Add to Favorites", bundle: bundle),
                    image: UIImage(systemName: favorite ? "star.slash" : "star")
                ) { [weak self] _ in
                    guard let self, let child else { return }
                    try? backend.setFavorite(child, included: !favorite)
                })
            } else {
                children.append(UIAction(
                    title: String(localized: "Preview", bundle: bundle),
                    image: UIImage(systemName: "eye")
                ) { [weak self] _ in self?.open(entry) })
                children.append(UIAction(
                    title: String(localized: "Save to Fila…", bundle: bundle),
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { [weak self] _ in self?.save(entry) })
            }
            // Copy and Move put the entry's location on the app's clipboard,
            // to be pasted into any file backend; a link is not carried
            // across backends and is not offered.
            var transfer: [UIMenuElement] = []
            if let child = try? path.appending(entry.name), entry.kind == .file || entry.kind == .directory {
                let location = FileLocation(backend: backend.id, path: child)
                transfer.append(UIAction(
                    title: String(localized: "Copy", bundle: bundle),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in BackendScreens.shell?.takeToClipboard([location], cut: false) })
                transfer.append(UIAction(
                    title: String(localized: "Move", bundle: bundle),
                    image: UIImage(systemName: "scissors")
                ) { _ in BackendScreens.shell?.takeToClipboard([location], cut: true) })
            }
            return UIMenu(title: entry.name, children: [
                UIMenu(options: .displayInline, children: children),
                UIMenu(options: .displayInline, children: transfer),
            ])
        }
    }

    public func collectionView(
        _: UICollectionView, willEndContextMenuInteraction _: UIContextMenuConfiguration, animator _: UIContextMenuInteractionAnimating?
    ) {
        holdsReloads = false
    }
}
#endif
