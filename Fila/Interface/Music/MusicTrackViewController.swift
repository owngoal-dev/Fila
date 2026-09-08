import AlertController
import FilaMedia
import Then
import UIKit

final class MusicTrackViewController: UITableViewController {
    private let track: MusicLibraryDatabase.Track
    private var details: MusicLibraryEditor.Details?
    private var isSaving = false
    private var load: Task<Void, Never>?

    init(track: MusicLibraryDatabase.Track) {
        self.track = track
        super.init(style: .insetGrouped)
        title = track.title.isEmpty ? String(localized: "Song Details") : track.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit { load?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Field")
        tableView.backgroundView = StatusView(content: .loading(String(localized: "Loading Music…")))
        load = Task { [weak self, track] in
            do {
                let result = try await MusicLibraryEditor.shared.details(id: track.id)
                guard let self, !Task.isCancelled else { return }
                details = result
                tableView.backgroundView = nil
                tableView.reloadData()
            } catch {
                guard let self, !Task.isCancelled else { return }
                tableView.backgroundView = StatusView(content: .message(
                    symbol: "music.note",
                    title: String(localized: "Music Unavailable"),
                    detail: error.localizedDescription
                ))
            }
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        details == nil ? 0 : MusicLibraryEditor.Field.allCases.count
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        guard details != nil else { return nil }
        return isSaving ? String(localized: "Saving…")
            : String(localized: "Fields with an arrow can be edited. Before each change, Fila saves a backup in Music Backups in Fila’s Documents folder.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = MusicLibraryEditor.Field.allCases[indexPath.row]
        return tableView.dequeueReusableCell(withIdentifier: "Field", for: indexPath).then {
            $0.contentConfiguration = UIListContentConfiguration.valueCell().with {
                $0.text = String(localized: field.title)
                $0.secondaryText = details?.values[field]
            }
            let editable = details?.editableFields.contains(field) == true
            $0.accessoryType = editable ? .disclosureIndicator : .none
            $0.selectionStyle = editable && !isSaving ? .default : .none
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSaving, let details else { return }
        let field = MusicLibraryEditor.Field.allCases[indexPath.row]
        guard details.editableFields.contains(field) else { return }
        let original = details.values[field] ?? ""
        let alert = AlertInputViewController(
            title: field.title,
            message: String.LocalizationValue(
                "Updates this song in the device’s music library. A backup is saved before the change."
            ),
            placeholder: .noPlaceholder,
            text: original,
            doneButtonText: String.LocalizationValue("Save")
        ) { [weak self] value in
            guard let self, value != original else { return }
            save(field, original: original, value: value)
        }
        present(alert, animated: true)
    }

    private func save(_ field: MusicLibraryEditor.Field, original: String, value: String) {
        guard !isSaving else { return }
        isSaving = true
        tableView.reloadData()
        Task { [self] in
            defer {
                isSaving = false
                tableView.reloadData()
            }
            do {
                details = try await MusicLibraryEditor.shared.save(
                    id: track.id,
                    field: field,
                    original: original,
                    value: value
                )
                let savedTitle = details?.values[.title] ?? ""
                title = savedTitle.isEmpty ? String(localized: "Song Details") : savedTitle
                Toast.show(String(localized: "Saved"))
            } catch {
                let alert = AlertViewController(
                    title: String(localized: "Unable to Save"),
                    message: error.localizedDescription
                ) { context in
                    context.allowSimpleDispose()
                    context.addAction(title: String.LocalizationValue("OK")) { context.dispose() }
                }
                if viewIfLoaded?.window != nil {
                    present(alert, animated: true)
                } else {
                    FeedbackAlert.show(String(localized: "Unable to Save"), message: error.localizedDescription)
                }
            }
        }
    }
}

private extension MusicLibraryEditor.Field {
    var title: String.LocalizationValue {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .composer: "Composer"
        case .year: "Year"
        case .trackNumber: "Track Number"
        case .discNumber: "Disc Number"
        case .comment: "Comment"
        }
    }
}
