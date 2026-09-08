import AlertController
import FilaProtocol
import Then
import UIKit

final class MusicTrackViewController: UITableViewController {
    private let track: MusicLibraryTrack
    private let delete: (MusicTrackViewController) -> Void
    private var details: MusicLibraryEditor.Details?
    private var isSaving = false
    private var load: Task<Void, Never>?

    init(track: MusicLibraryTrack, delete: @escaping (MusicTrackViewController) -> Void) {
        self.delete = delete
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
        tableView.register(MusicTrackPreviewCell.self, forCellReuseIdentifier: "Preview")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        configureMenu()
    }

    private func configureMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: FilaMenu.groups([
                UIAction(title: String(localized: "Export"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.exportMusic()
                },
            ], [
                UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"),
                         attributes: .destructive) { [weak self] _ in
                    guard let self, !isSaving else { return }
                    delete(self)
                },
            ]))
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    private func exportMusic() {
        guard !isSaving else { return }
        Task { [self] in
            do {
                let path = try await MusicLibraryEditor.shared.exportPath(id: track.id)
                guard viewIfLoaded?.window != nil else { return }
                let title = details?.values[.title] ?? track.title
                let name = MusicLibraryEditor.exportName(title: title, sourcePath: path)
                let picker = SaveDestinationViewController(fileName: name, link: FileSession.shared.link) { [weak self] target in
                    self?.exportMusic(from: path, to: target)
                }
                presentAsSheet(UINavigationController(rootViewController: picker))
            } catch {
                FeedbackAlert.show(String(localized: "Unable to Export"), message: error.localizedDescription)
            }
        }
    }

    private func exportMusic(from path: String, to target: URL) {
        guard !isSaving else { return }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let progress = AlertProgressIndicatorViewController(
            title: String.LocalizationValue("Saving…"),
            message: String.LocalizationValue("Copying…")
        )
        present(progress, animated: true)
        Task { [self] in
            var failure: Error?
            do {
                let session = FileSession.shared
                let staged = try await session.stage(path)
                let workspace = staged.deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: workspace) }
                let named = workspace.appendingPathComponent(target.lastPathComponent)
                if named != staged { try FileManager.default.moveItem(at: staged, to: named) }
                let result = try await session.operations.awaitJob(
                    JobRequest(kind: .copy, sources: [named.path], destination: target.deletingLastPathComponent().path),
                    kind: .copy,
                    subtitle: target.path,
                    feedback: .silent
                )
                guard result.code == .success else { throw result }
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                isSaving = false
                navigationItem.rightBarButtonItem?.isEnabled = true
                if let failure {
                    FeedbackAlert.show(String(localized: "Unable to Export"), message: FailureMessage.text(for: failure))
                } else {
                    Toast.show(String(localized: "Saved"))
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isSaving else { return }
        reload()
    }

    private func reload() {
        load?.cancel()
        load = Task { [weak self, track] in
            do {
                let result = try await MusicLibraryEditor.shared.details(id: track.id)
                guard let self, !Task.isCancelled else { return }
                guard details?.values != result.values || details?.editableFields != result.editableFields else { return }
                applyDetails(result)
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard details == nil else { return }
                FeedbackAlert.show(String(localized: "Music Unavailable"), message: error.localizedDescription)
            }
        }
    }

    private func applyDetails(_ result: MusicLibraryEditor.Details) {
        details = result
        let savedTitle = result.values[.title] ?? ""
        title = savedTitle.isEmpty ? String(localized: "Song Details") : savedTitle
        let preview = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? MusicTrackPreviewCell
        preview?.show(track, details: result)
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
        tableView.layoutIfNeeded()
    }

    override func numberOfSections(in _: UITableView) -> Int { 2 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        return details == nil ? 0 : MusicLibraryEditor.Field.allCases.count
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1, details != nil else { return nil }
        return String(localized: "Tap a field with an arrow to edit it.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Preview", for: indexPath) as! MusicTrackPreviewCell
            cell.show(track, details: details)
            return cell
        }
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
        guard indexPath.section == 1, !isSaving, let details else { return }
        let field = MusicLibraryEditor.Field.allCases[indexPath.row]
        guard details.editableFields.contains(field) else { return }
        let original = details.values[field] ?? ""
        let alert = AlertInputViewController(
            title: field.title,
            message: String.LocalizationValue(
                "Edit this song’s details in the device’s music library."
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
        load?.cancel()
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let progress = AlertProgressIndicatorViewController(
            title: String.LocalizationValue("Saving…"),
            message: String.LocalizationValue("Updating the music library. Keep Fila open until this finishes.")
        )
        present(progress, animated: true)
        Task { [self] in
            var failure: Error?
            do {
                let result = try await MusicLibraryEditor.shared.save(
                    id: track.id,
                    field: field,
                    original: original,
                    value: value
                )
                applyDetails(result)
            } catch { failure = error }
            isSaving = false
            navigationItem.rightBarButtonItem?.isEnabled = true
            progress.dismiss(animated: true) {
                if let failure {
                    FeedbackAlert.show(String(localized: "Unable to Save"), message: failure.localizedDescription)
                } else {
                    Toast.show(String(localized: "Saved"))
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
