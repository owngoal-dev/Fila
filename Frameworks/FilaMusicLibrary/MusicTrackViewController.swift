import FilaCore
import Then
import UIKit

/// One song: its artwork and the fields the library lets Fila edit, plus
/// export into the file tree and deletion from the library.
///
/// Export stages the library's own file through the shell, renames it to
/// the title and publishes it as a copy job, so a song lands in the
/// browser as a task and never as a raw path.
final class MusicTrackViewController: TabContentTableViewController, TabContentDecorationSource {
    private let track: MusicLibraryTrack
    private let root: PathBarView.Crumb
    private let delete: (MusicTrackViewController) -> Void
    private var details: MusicLibraryEditor.Details?
    private var isSaving = false
    private var load: Task<Void, Never>?

    private var bundle: Bundle { MusicLibraryBackend.bundle }

    /// `root` is the library's own crumb; this screen draws it first and
    /// pops back to the library from it.
    init(track: MusicLibraryTrack, root: PathBarView.Crumb, delete: @escaping (MusicTrackViewController) -> Void) {
        self.delete = delete
        self.track = track
        self.root = root
        super.init(style: .insetGrouped)
        title = track.title.isEmpty ? String(localized: "Song Details", bundle: bundle) : track.title
        trailingNavigationItems = [Self.actionsItem(menu: UIMenu(children: [
                UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Export", bundle: bundle),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { [weak self] _ in
                        self?.exportMusic()
                    },
                ]),
                UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Delete from Library", bundle: bundle),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in
                        guard let self, !isSaving else { return }
                        delete(self)
                    },
                ]),
            ]))]
    }

    // MARK: - Decoration

    /// The library, then this song under its current title.
    func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        [root, PathBarView.Crumb(title: title ?? "", target: track.id.description, icon: UIImage(systemName: "music.note"))]
    }

    /// The only earlier crumb is the library.
    func tabContent(_: TabContentViewController, didSelectDecorationCrumb _: PathBarView.Crumb) {
        guard let navigation = navigationController,
              let list = navigation.viewControllers.last(where: { $0 is MusicLibraryViewController }) else { return }
        navigation.popToViewController(list, animated: true)
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
    }

    // MARK: - Export

    private func exportMusic() {
        guard !isSaving, let shell = BackendScreens.shell else { return }
        Task { [self] in
            do {
                let path = try await MusicLibraryEditor.shared.exportPath(id: track.id)
                guard viewIfLoaded?.window != nil else { return }
                let title = details?.values[.title] ?? track.title
                let name = MusicLibraryEditor.exportName(title: title, sourcePath: path)
                let picker = shell.saveDestinationPicker(fileName: name) { [weak self] target in
                    self?.exportMusic(from: path, to: target)
                }
                shell.presentSheet(picker, from: self)
            } catch {
                shell.alert(title: String(localized: "Unable to Export", bundle: bundle), message: error.localizedDescription)
            }
        }
    }

    private func exportMusic(from path: String, to target: URL) {
        guard !isSaving, let shell = BackendScreens.shell else { return }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        // Resolved here, against this framework's catalogue: AlertController
        // looks a `LocalizationValue` up in the app bundle, where these keys
        // do not live.
        let progress = AlertProgressIndicatorViewController(
            title: String(localized: "Saving…", bundle: bundle),
            message: String(localized: "Copying…", bundle: bundle)
        )
        present(progress, animated: true)
        Task { [self] in
            var failure: Error?
            do {
                let staged = try await shell.stage(path)
                let workspace = staged.deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: workspace) }
                let named = workspace.appendingPathComponent(target.lastPathComponent)
                if named != staged { try FileManager.default.moveItem(at: staged, to: named) }
                try await shell.copy(named, into: target.deletingLastPathComponent().path, subtitle: target.path)
            } catch { failure = error }
            progress.dismiss(animated: true) { [self] in
                isSaving = false
                navigationItem.rightBarButtonItem?.isEnabled = true
                if let failure {
                    shell.alert(title: String(localized: "Unable to Export", bundle: bundle), message: shell.failureText(for: failure))
                } else {
                    shell.toast(String(localized: "Saved", bundle: bundle))
                }
            }
        }
    }

    // MARK: - Details

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
                BackendScreens.shell?.alert(
                    title: String(localized: "Music Unavailable", bundle: bundle),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func applyDetails(_ result: MusicLibraryEditor.Details) {
        details = result
        let savedTitle = result.values[.title] ?? ""
        title = savedTitle.isEmpty ? String(localized: "Song Details", bundle: bundle) : savedTitle
        reloadDecoration()
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

    func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1, details != nil else { return nil }
        return String(localized: "Tap a field with an arrow to edit it.", bundle: bundle)
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
                $0.text = fieldTitle(field)
                $0.secondaryText = details?.values[field]
            }
            let editable = details?.editableFields.contains(field) == true
            $0.accessoryType = editable ? .disclosureIndicator : .none
            $0.selectionStyle = editable && !isSaving ? .default : .none
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !isSaving, let details else { return }
        let field = MusicLibraryEditor.Field.allCases[indexPath.row]
        guard details.editableFields.contains(field) else { return }
        let original = details.values[field] ?? ""
        let alert = AlertInputViewController(
            title: fieldTitle(field),
            message: String(localized: "Edit this song’s details in the device’s music library.", bundle: bundle),
            placeholder: "",
            text: original,
            cancelButtonText: String(localized: "Cancel", bundle: bundle),
            doneButtonText: String(localized: "Save", bundle: bundle)
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
            title: String(localized: "Saving…", bundle: bundle),
            message: String(localized: "Updating the music library. Keep Fila open until this finishes.", bundle: bundle)
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
            progress.dismiss(animated: true) { [self] in
                if let failure {
                    BackendScreens.shell?.alert(
                        title: String(localized: "Unable to Save", bundle: bundle),
                        message: failure.localizedDescription
                    )
                } else {
                    BackendScreens.shell?.toast(String(localized: "Saved", bundle: bundle))
                }
            }
        }
    }

    private func fieldTitle(_ field: MusicLibraryEditor.Field) -> String {
        switch field {
        case .title: String(localized: "Title", bundle: bundle)
        case .artist: String(localized: "Artist", bundle: bundle)
        case .album: String(localized: "Album", bundle: bundle)
        case .albumArtist: String(localized: "Album Artist", bundle: bundle)
        case .genre: String(localized: "Genre", bundle: bundle)
        case .composer: String(localized: "Composer", bundle: bundle)
        case .year: String(localized: "Year", bundle: bundle)
        case .trackNumber: String(localized: "Track Number", bundle: bundle)
        case .discNumber: String(localized: "Disc Number", bundle: bundle)
        case .comment: String(localized: "Comment", bundle: bundle)
        }
    }
}
