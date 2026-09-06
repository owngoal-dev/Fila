import AlertController
import FilaMedia
import Then
import UIKit

final class MusicLibraryViewController: UITableViewController, UISearchResultsUpdating {
    private var tracks: [MusicLibraryDatabase.Track] = []
    private var rows: [MusicLibraryDatabase.Track] = []
    private var importing = false
    private var load: Task<Void, Never>?

    init() {
        super.init(style: .plain)
        configureMenu()
    }

    private func configureMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: String(localized: "Import Music"), image: UIImage(systemName: "square.and.arrow.down"), attributes: importing ? .disabled : []) { [weak self] _ in
                self?.chooseMusic()
            },
            UIAction(title: String(localized: "Refresh"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() },
            UIAction(title: String(localized: "Show Library Folder"), image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.navigationController?.pushViewController(BrowserViewController(directory: "/var/mobile/Media/iTunes_Control"), animated: true)
            },
        ]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    private func chooseMusic() {
        let session = FileSession.shared
        let directory = session.hello?.isPrivileged == true ? "/var/mobile" : NSHomeDirectory()
        let picker = SaveDestinationViewController(
            directory: URL(fileURLWithPath: directory, isDirectory: true),
            fileTypes: MusicLibraryEditor.audioExtensions, link: session.link
        ) { [weak self] file in self?.importMusic(file) }
        presentAsSheet(UINavigationController(rootViewController: picker))
    }

    private func importMusic(_ file: URL) {
        guard !importing else { return }
        importing = true
        configureMenu()
        let progress = AlertProgressIndicatorViewController(title: "Importing Music…", message: "Keep Fila open until the import finishes.")
        present(progress, animated: true)
        Task {
            var failure: Error?
            do { try await MusicLibraryEditor.shared.importTrack(from: file.path) }
            catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                importing = false
                configureMenu()
                if let failure {
                    FeedbackAlert.show(String(localized: "Unable to Import Music"), message: FailureMessage.text(for: failure))
                } else {
                    Toast.show(String(localized: "Music Imported"))
                    reload()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { load?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Music")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Song")
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        load?.cancel()
        if tracks.isEmpty { tableView.backgroundView = StatusView(content: .loading(String(localized: "Loading Music…"))) }
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
                if tracks.isEmpty {
                    tableView.backgroundView = StatusView(content: .message(symbol: "music.note", title: String(localized: "Music Unavailable"), detail: error.localizedDescription))
                } else {
                    FeedbackAlert.show(String(localized: "Unable to Refresh"), message: error.localizedDescription)
                }
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) { filter() }

    private func filter() {
        let query = navigationItem.searchController?.searchBar.text ?? ""
        rows = tracks.filter { query.isEmpty || $0.title.localizedStandardContains(query)
            || $0.artist.localizedStandardContains(query) || $0.album.localizedStandardContains(query) }
        tableView.reloadData()
        tableView.backgroundView = rows.isEmpty ? StatusView(content: .message(
            symbol: "music.note", title: query.isEmpty ? String(localized: "No Music") : String(localized: "No Matches"),
            detail: query.isEmpty ? String(localized: "Import an audio file from the More menu to add it to this device’s music library.") : nil
        )) : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let track = rows[indexPath.row]
        return tableView.dequeueReusableCell(withIdentifier: "Song", for: indexPath).then {
            $0.contentConfiguration = UIListContentConfiguration.valueCell().with {
                $0.text = track.title.isEmpty ? String(localized: "Untitled") : track.title
                $0.secondaryText = track.artist
                $0.image = UIImage(systemName: "music.note")
            }
            $0.accessoryType = .disclosureIndicator
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(MusicTrackViewController(track: rows[indexPath.row]), animated: true)
    }
}
