import FilaMedia
import Then
import UIKit

final class MusicLibraryViewController: UITableViewController, UISearchResultsUpdating {
    private var tracks: [MusicLibraryDatabase.Track] = []
    private var rows: [MusicLibraryDatabase.Track] = []
    private var load: Task<Void, Never>?

    init() {
        super.init(style: .plain)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: String(localized: "Refresh"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() },
            UIAction(title: String(localized: "Show Library Folder"), image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.navigationController?.pushViewController(BrowserViewController(directory: "/var/mobile/Media/iTunes_Control"), animated: true)
            },
        ]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
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
                    Toast.show(String(localized: "Unable to Refresh"), detail: error.localizedDescription, symbol: "exclamationmark.triangle")
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
            detail: query.isEmpty ? String(localized: "Songs in this device’s music library appear here.") : nil
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
