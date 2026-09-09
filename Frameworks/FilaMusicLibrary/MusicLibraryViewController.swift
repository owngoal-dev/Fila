import FilaCore
import MediaPlayer
import Then
import UIKit

/// The songs in the device's music library, with import, delete and the
/// jump into the library's own folder.
///
/// The list is `MusicLibraryEditor.tracks()`, reloaded on every hint from
/// the backend; the edits go through the same editor and hold reloads
/// until the library has confirmed them, so a half-applied change is
/// never listed as done.
final class MusicLibraryViewController: BackendListViewController<MusicLibraryTrack>, BackendRootScreen,
    UISearchResultsUpdating, UICollectionViewDelegate
{
    private let backend: MusicLibraryBackend
    /// The local backend the library folder lives in; nil without one, and
    /// then the folder is not offered.
    private let local: LocalFileBackend?
    private var filter = ""
    private var isChangingLibrary = false
    private let cell = UICollectionView.CellRegistration<MusicTrackCell, MusicLibraryTrack> { cell, _, track in
        cell.show(track)
    }

    private var bundle: Bundle { MusicLibraryBackend.bundle }

    init(backend: MusicLibraryBackend, local: LocalFileBackend?) {
        self.backend = backend
        self.local = local
        super.init()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] done in done(self?.menuElements() ?? []) },
            ])
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More", bundle: bundle)
    }

    private func menuElements() -> [UIMenuElement] {
        [
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Import Music", bundle: bundle),
                    image: UIImage(systemName: "square.and.arrow.down"),
                    attributes: isChangingLibrary || backend.files == nil ? .disabled : []
                ) { [weak self] _ in
                    self?.chooseMusic()
                },
            ]),
            UIMenu(options: .displayInline, children: local == nil ? [] : [
                UIAction(
                    title: String(localized: "Show Library Folder", bundle: bundle),
                    image: UIImage(systemName: "folder")
                ) { [weak self] _ in
                    self?.showLibraryFolder()
                },
            ]),
        ]
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Music", bundle: bundle)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        definesPresentationContext = true
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        let search = UISearchController(searchResultsController: nil).then {
            $0.searchResultsUpdater = self
            $0.obscuresBackgroundDuringPresentation = false
            $0.hidesNavigationBarDuringPresentation = false
        }
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        for name in [Notification.Name.MPMediaLibraryDidChange, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backend.libraryChanged() }
            }
        }
    }

    // MARK: - List hooks

    override func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    override func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: MusicLibraryTrack) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
    }

    override func load() -> AsyncThrowingStream<[MusicLibraryTrack], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await MusicLibraryEditor.shared.tracks())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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

    override func arrange(_ items: [MusicLibraryTrack]) -> [MusicLibraryTrack] {
        guard !filter.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(filter)
                || $0.artist.localizedStandardContains(filter)
                || $0.album.localizedStandardContains(filter)
        }
    }

    override var statusContent: StatusView.Content? {
        if let loadFailure {
            return .message(
                symbol: "music.note",
                title: String(localized: "Music Unavailable", bundle: bundle),
                detail: loadFailure.localizedDescription
            )
        }
        if isLoading, items.isEmpty {
            return .loading(String(localized: "Loading Music…", bundle: bundle))
        }
        guard visible.isEmpty else { return nil }
        return .message(
            symbol: "music.note",
            title: filter.isEmpty ? String(localized: "No Music", bundle: bundle) : String(localized: "No Matches", bundle: bundle),
            detail: filter.isEmpty
                ? String(localized: "Import an audio file to add it to this device’s music library.", bundle: bundle)
                : nil
        )
    }

    override func loadDidFail(_ error: Error, hadRows: Bool) {
        guard hadRows else { return }
        BackendScreens.shell?.alert(
            title: String(localized: "Unable to Refresh", bundle: bundle),
            message: error.localizedDescription
        )
    }

    func updateSearchResults(for search: UISearchController) {
        let text = search.searchBar.text ?? ""
        guard text != filter else { return }
        filter = text
        rearrange(animated: false)
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !isChangingLibrary, let track = dataSource.itemIdentifier(for: indexPath) else { return }
        showDetails(of: track)
    }

    private func showDetails(of track: MusicLibraryTrack) {
        let detail = MusicTrackViewController(track: track) { [weak self] presenter in
            self?.confirmDelete(track, from: presenter)
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isChangingLibrary, let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete", bundle: bundle)
        ) { [weak self] _, _, completion in
            completion(false)
            guard let self else { return }
            confirmDelete(track, from: self)
        }
        return UISwipeActionsConfiguration(actions: [action]).then {
            $0.performsFirstActionWithFullSwipe = false
        }
    }

    private func showLibraryFolder() {
        guard let shell = BackendScreens.shell, let local,
              let path = local.servicePath(forAbsolute: MusicLibraryBackend.libraryDirectory),
              let browser = shell.browser(for: BackendLocation(backend: local.id, item: path.description))
        else { return }
        navigationController?.pushViewController(browser, animated: true)
    }

    // MARK: - Import

    private func chooseMusic() {
        guard let shell = BackendScreens.shell, backend.files != nil else { return }
        let picker = shell.filePicker(fileTypes: MusicLibraryEditor.audioExtensions) { [weak self] file in
            self?.importMusic(file)
        }
        shell.presentSheet(picker, from: self)
    }

    private func importMusic(_ file: URL) {
        guard !isChangingLibrary, let files = backend.files else { return }
        beginChange()
        // Resolved against this framework's catalogue; AlertController would
        // look a `LocalizationValue` up in the app bundle.
        let progress = AlertProgressIndicatorViewController(
            title: String(localized: "Importing Music…", bundle: bundle),
            message: String(localized: "Keep Fila open until the import finishes.", bundle: bundle)
        )
        present(progress, animated: true)
        Task {
            var failure: Error?
            do {
                _ = try await MusicLibraryEditor.shared.importTrack(from: file.path, files: files)
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                endChange()
                if let failure {
                    BackendScreens.shell?.alert(
                        title: String(localized: "Unable to Import Music", bundle: bundle),
                        message: BackendScreens.shell?.failureText(for: failure) ?? failure.localizedDescription
                    )
                } else {
                    BackendScreens.shell?.toast(String(localized: "Music Imported", bundle: bundle))
                }
            }
        }
    }

    // MARK: - Delete

    private func confirmDelete(_ track: MusicLibraryTrack, from presenter: UIViewController) {
        guard !isChangingLibrary, let shell = BackendScreens.shell else { return }
        shell.confirmPermanentDeletion(
            from: presenter,
            title: String(localized: "Delete from Library", bundle: bundle),
            message: String(localized: "“\(track.title)” will be deleted from this device’s music library.", bundle: bundle),
            confirmTitle: String(localized: "Delete", bundle: bundle)
        ) { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            deleteMusic(track, from: presenter)
        }
    }

    private func deleteMusic(_ track: MusicLibraryTrack, from presenter: UIViewController) {
        guard !isChangingLibrary else { return }
        beginChange()
        let progress = AlertProgressIndicatorViewController(
            title: String(localized: "Deleting…", bundle: bundle),
            message: String(localized: "Updating the music library. Keep Fila open until this finishes.", bundle: bundle)
        )
        presenter.present(progress, animated: true)
        Task { [self] in
            var failure: Error?
            do {
                _ = try await MusicLibraryEditor.shared.deleteTrack(id: track.id)
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                endChange()
                if failure == nil, presenter !== self, navigationController?.topViewController === presenter {
                    navigationController?.popViewController(animated: true)
                }
                if let failure {
                    BackendScreens.shell?.alert(
                        title: String(localized: "Unable to Delete Music", bundle: bundle),
                        message: failure.localizedDescription
                    )
                }
            }
        }
    }

    /// A change in flight holds every reload: the list must not relist
    /// halfway through the library's own update. The hint that follows the
    /// change runs once it is released.
    private func beginChange() {
        isChangingLibrary = true
        holdsReloads = true
    }

    private func endChange() {
        isChangingLibrary = false
        refresher.endRefreshing()
        backend.libraryChanged()
        holdsReloads = false
    }
}
