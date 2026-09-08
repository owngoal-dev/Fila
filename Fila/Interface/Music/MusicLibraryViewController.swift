import AlertController
import MediaPlayer
import Then
import UIKit

final class MusicLibraryViewController: UITableViewController, UISearchResultsUpdating {
    private var tracks: [MusicLibraryTrack]?
    private var rows: [MusicLibraryTrack] = []
    private var dataSource: UITableViewDiffableDataSource<Int, Int64>!
    private var isChangingLibrary = false
    private var load: Task<Void, Never>?

    init() {
        super.init(style: .plain)
        configureMenu()
    }

    private func configureMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: FilaMenu.groups([
                UIAction(
                    title: String(localized: "Import Music"),
                    image: UIImage(systemName: "square.and.arrow.down"),
                    attributes: isChangingLibrary ? .disabled : []
                ) { [weak self] _ in
                    self?.chooseMusic()
                },
            ], [
                UIAction(
                    title: String(localized: "Show Library Folder"),
                    image: FilePresentation.image(kind: .directory, name: "iTunes_Control")
                ) { [weak self] _ in
                    self?.navigationController?.pushViewController(
                        BrowserViewController(directory: "/var/mobile/Media/iTunes_Control"),
                        animated: true
                    )
                },
            ]))
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    private func chooseMusic() {
        let session = FileSession.shared
        let picker = SaveDestinationViewController(
            fileTypes: MusicLibraryEditor.audioExtensions, link: session.link
        ) { [weak self] file in self?.importMusic(file) }
        presentAsSheet(UINavigationController(rootViewController: picker))
    }

    private func importMusic(_ file: URL) {
        guard !isChangingLibrary else { return }
        isChangingLibrary = true
        load?.cancel()
        configureMenu()
        let progress = AlertProgressIndicatorViewController(
            title: String.LocalizationValue("Importing Music…"),
            message: String.LocalizationValue("Keep Fila open until the import finishes.")
        )
        present(progress, animated: true)
        Task {
            var failure: Error?
            do {
                let result = try await MusicLibraryEditor.shared.importTrack(from: file.path)
                await applyTracks(result)
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                isChangingLibrary = false
                configureMenu()
                refreshControl?.endRefreshing()
                if let failure {
                    FeedbackAlert.show(
                        String(localized: "Unable to Import Music"),
                        message: FailureMessage.text(for: failure)
                    )
                } else {
                    Toast.show(String(localized: "Music Imported"))
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit { load?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Music")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        definesPresentationContext = true
        tableView.register(MusicTrackCell.self, forCellReuseIdentifier: "Song")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        dataSource = UITableViewDiffableDataSource<Int, Int64>(tableView: tableView) { [weak self] table, indexPath, id in
            guard let track = self?.rows.first(where: { $0.id == id }) else { return nil }
            let cell = table.dequeueReusableCell(withIdentifier: "Song", for: indexPath) as! MusicTrackCell
            cell.show(track)
            return cell
        }
        tableView.keyboardDismissMode = .onDrag
        let search = UISearchController(searchResultsController: nil).then {
            $0.searchResultsUpdater = self
            $0.obscuresBackgroundDuringPresentation = false
            $0.hidesNavigationBarDuringPresentation = false
        }
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        for name in [Notification.Name.MPMediaLibraryDidChange, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: name, object: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func libraryChanged() {
        guard viewIfLoaded?.window != nil, !isChangingLibrary else { return }
        reload()
    }

    @objc private func reload() {
        guard !isChangingLibrary else { return }
        load?.cancel()
        if tracks == nil, tableView.backgroundView == nil {
            tableView.backgroundView = StatusView(content: .loading(String(localized: "Loading Music…")))
        }
        load = Task { [weak self] in
            do {
                let result = try await MusicLibraryEditor.shared.tracks()
                guard let self, !Task.isCancelled else { return }
                tracks = result
                filter()
                refreshControl?.endRefreshing()
            } catch {
                guard let self, !Task.isCancelled else { return }
                refreshControl?.endRefreshing()
                if tracks == nil {
                    tableView.backgroundView = StatusView(content: .message(
                        symbol: "music.note",
                        title: String(localized: "Music Unavailable"),
                        detail: error.localizedDescription
                    ))
                } else {
                    FeedbackAlert.show(String(localized: "Unable to Refresh"), message: error.localizedDescription)
                }
            }
        }
    }

    func updateSearchResults(for _: UISearchController) {
        filter()
    }

    private func applyTracks(_ result: [MusicLibraryTrack]) async {
        tracks = result
        await withCheckedContinuation { continuation in
            filter { continuation.resume() }
        }
    }

    private func filter(completion: (() -> Void)? = nil) {
        guard let tracks else { completion?(); return }
        let query = navigationItem.searchController?.searchBar.text ?? ""
        let filtered = tracks.filter { query.isEmpty || $0.title.localizedStandardContains(query)
            || $0.artist.localizedStandardContains(query) || $0.album.localizedStandardContains(query)
        }
        tableView.backgroundView = filtered.isEmpty ? StatusView(content: .message(
            symbol: "music.note",
            title: query.isEmpty ? String(localized: "No Music") : String(localized: "No Matches"),
            detail: query.isEmpty
                ? String(localized: "Import an audio file to add it to this device’s music library.")
                : nil
        )) : nil
        guard rows != filtered else { completion?(); return }
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = filtered
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        snapshot.reconfigureItems(rows.filter { previous[$0.id] != nil && previous[$0.id] != $0 }.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty && !UIAccessibility.isReduceMotionEnabled,
                         completion: completion)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !isChangingLibrary else { return nil }
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let track = rows.first(where: { $0.id == id }) else { return nil }
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete")
        ) { [weak self] _, _, completion in
            completion(false)
            guard let self else { return }
            PermanentDeleteConfirmation.present(
                from: self,
                title: String(localized: "Delete from Library"),
                message: String(localized: "“\(track.title)” will be deleted from this device’s music library."),
                confirmTitle: String(localized: "Delete")
            ) { [weak self] in self?.deleteMusic(track) }
        }
        return UISwipeActionsConfiguration(actions: [action]).then {
            $0.performsFirstActionWithFullSwipe = false
        }
    }

    private func deleteMusic(_ track: MusicLibraryTrack) {
        guard !isChangingLibrary else { return }
        isChangingLibrary = true
        load?.cancel()
        configureMenu()
        let progress = AlertProgressIndicatorViewController(
            title: String.LocalizationValue("Deleting…"),
            message: String.LocalizationValue("Updating the music library. Keep Fila open until this finishes.")
        )
        present(progress, animated: true)
        Task { [self] in
            var failure: Error?
            do {
                let result = try await MusicLibraryEditor.shared.deleteTrack(id: track.id)
                await applyTracks(result)
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                isChangingLibrary = false
                configureMenu()
                refreshControl?.endRefreshing()
                if let failure {
                    FeedbackAlert.show(String(localized: "Unable to Delete Music"), message: failure.localizedDescription)
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isChangingLibrary, let id = dataSource.itemIdentifier(for: indexPath),
              let track = rows.first(where: { $0.id == id }) else { return }
        navigationController?.pushViewController(MusicTrackViewController(track: track), animated: true)
    }
}
