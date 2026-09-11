import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaLog
import Then
import UIKit

/// Appearance and behaviour on one page: what the browser shows, what it does
/// with a delete, what it runs, and the order of the places in the sidebar.
/// They were two pushed screens with four rows between them, which is a
/// hierarchy the settings did not earn.
///
/// Presets stay in the list when disabled so they can be reordered and enabled
/// again.
final class GeneralSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case browsing, fileOperations, scripts, presets }
    private enum BrowsingRow: Int, CaseIterable { case launchLocation, showsHidden, recordsRecents }

    private let preferences = AppPreferences.shared
    private let session = FileSession.shared
    private var presets = GeneralSettingsViewController.offeredPresets()

    /// The presets this launch can show at all, in the user's order. A
    /// catalogue preset needs its module — a copy without Applications has
    /// no row to hide — and a local preset needs a place this root offers:
    /// a sandboxed container has no bootstrap and no trash of this kind.
    /// Hidden presets stay so they can be turned back on; absent ones are
    /// not listed, and their saved order is kept for a launch that has them.
    private static func offeredPresets() -> [LocalPreset] {
        let local = FileSession.shared.local
        return local.orderedPresets.filter { preset in
            switch preset {
            case .applications: BackendComposition.registry.backend(.applications) != nil
            case .music: BackendComposition.registry.backend(.musicLibrary) != nil
            default: local.offersPreset(preset)
            }
        }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadWithAnimation()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "General")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.do {
            $0.rowHeight = UITableView.automaticDimension
            $0.estimatedRowHeight = FilaUI.minimumTapTarget
            $0.allowsSelection = false
            $0.contentInset.bottom = FilaUI.Spacing.settingsTail
        }
        setEditing(true, animated: false)
    }

    override func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .browsing: BrowsingRow.allCases.count
        case .presets: presets.count
        default: 1
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .browsing: String(localized: "Browsing")
        case .fileOperations: String(localized: "File Operations")
        case .scripts: String(localized: "Scripts")
        case .presets: String(localized: "Places")
        case nil: nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .browsing:
            String(localized: "Turning off Remember Recents also deletes the history already recorded.")
        case .fileOperations:
            String(localized: "Move deleted items to the trash so they can be put back.")
        case .scripts:
            String(localized: "Fila finds the program a script needs if it isn't in the usual place. Turn this off to run scripts exactly as written.")
        case .presets:
            String(localized: "Drag to reorder. Turn off a place to hide it.")
        case nil: nil
        }
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if Section(rawValue: indexPath.section) == .browsing,
           BrowsingRow(rawValue: indexPath.row) == .launchLocation
        {
            return launchLocationCell(cell)
        }
        let title: String
        let enabled: Bool
        let update: (Bool) -> Void
        switch Section(rawValue: indexPath.section) {
        case .presets:
            let preset = presets[indexPath.row]
            title = name(of: preset)
            enabled = session.local.isPresetEnabled(preset)
            update = { [session] enabled in
                do { try session.local.setPreset(preset, enabled: enabled) }
                catch { FilaLog.error("preset not saved: \(error)") }
            }
            cell.showsReorderControl = true
        case .fileOperations:
            title = String(localized: "Use Trash")
            enabled = preferences.usesTrash
            update = { [preferences] in preferences.usesTrash = $0 }
        case .scripts:
            title = String(localized: "Find Script Interpreters")
            enabled = preferences.redirectsScriptInterpreters
            update = { [preferences] in preferences.redirectsScriptInterpreters = $0 }
        case .browsing where BrowsingRow(rawValue: indexPath.row) == .recordsRecents:
            title = String(localized: "Remember Recents")
            enabled = preferences.recordsRecents
            update = { [preferences] in preferences.recordsRecents = $0 }
        default:
            title = String(localized: "Show Hidden Files")
            enabled = session.showsHidden
            update = { [session] in session.setShowsHidden($0) }
        }
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        let toggle = UISwitch().then {
            $0.isOn = enabled
            $0.accessibilityLabel = title
        }
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            update(toggle.isOn)
            // Browsers are behind a modal and get no callback of their own,
            // so the change has to be announced.
            NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
        }, for: .valueChanged)
        cell.editingAccessoryView = toggle
        cell.accessoryView = toggle
        return cell
    }

    /// A pull-down button rather than a pushed list of radio rows. The three
    /// fixed answers sit above the same Favorites / Mount Points / Recents
    /// submenus every Go menu draws — a folder the user already
    /// bookmarked is the likeliest fourth answer, and building it out of
    /// `FilaMenu.collections` means it stays the same list in both places.
    private func launchLocationCell(_ cell: UITableViewCell) -> UITableViewCell {
        let title = String(localized: "Open at Launch")
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let selected = preferences.launchLocation
        let button = UIButton(type: .system).then {
            $0.setTitle(Self.name(of: selected), for: .normal)
            $0.titleLabel?.font = .preferredFont(forTextStyle: .body)
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.accessibilityLabel = title
            $0.showsMenuAsPrimaryAction = true
        }
        let choose: (LaunchLocation) -> Void = { [weak self] location in
            self?.preferences.launchLocation = location
            self?.tableView.reloadWithAnimation()
        }
        let fixed: [UIMenuElement] = [LaunchLocation.root, .home, .lastVisited].map { location in
            UIAction(
                title: Self.name(of: location),
                state: selected == location ? .on : .off
            ) { _ in choose(location) }
        }
        button.menu = UIMenu(children: FilaMenu.groups(
            fixed,
            FilaMenu.collections { path in choose(.folder(path)) }
        ))
        button.sizeToFit()
        cell.editingAccessoryView = button
        cell.accessoryView = button
        return cell
    }

    private static func name(of location: LaunchLocation) -> String {
        switch location {
        case .root: String(localized: "Root")
        case .home: String(localized: "Home")
        case .lastVisited: String(localized: "Last Visited")
        // The folder's own name, not its path: the button is one line beside
        // a title and a full path would push the row's own label off it.
        case let .folder(path): path == "/" ? "/" : (path as NSString).lastPathComponent
        }
    }

    override func tableView(
        _: UITableView,
        editingStyleForRowAt _: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(
        _: UITableView,
        shouldIndentWhileEditingRowAt _: IndexPath
    ) -> Bool {
        false
    }

    override func tableView(_: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == Section.presets.rawValue
    }

    override func tableView(
        _: UITableView,
        targetIndexPathForMoveFromRowAt source: IndexPath,
        toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
        guard proposed.section == source.section else {
            return IndexPath(row: proposed.section < source.section ? 0 : presets.count - 1, section: source.section)
        }
        return proposed
    }

    override func tableView(_: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let preset = presets.remove(at: source.row)
        presets.insert(preset, at: destination.row)
        // The list shows only what this launch offers; the saved order
        // covers every preset. The shown ones take their new order in the
        // slots they already occupy, and an absent preset keeps its place
        // for the launch that has it.
        var order = session.local.orderedPresets
        var moved = presets.makeIterator()
        for index in order.indices where presets.contains(order[index]) {
            guard let next = moved.next() else { break }
            order[index] = next
        }
        do { try session.local.setPresetOrder(order) }
        catch { FilaLog.error("preset order not saved: \(error)") }
    }

    private func name(of preset: LocalPreset) -> String {
        switch preset {
        case .root:
            if case .local(.container) = FileSession.shared.hello?.backend {
                return String(localized: "Home")
            }
            return String(localized: "Root")
        case .bootstrap: return String(localized: "Bootstrap")
        case .applications: return String(localized: "Applications")
        case .mobile: return String(localized: "Mobile")
        case .pictures: return String(localized: "Pictures")
        case .music: return String(localized: "Music")
        case .inbox: return String(localized: "Inbox")
        case .trash: return String(localized: "Trash")
        }
    }
}
