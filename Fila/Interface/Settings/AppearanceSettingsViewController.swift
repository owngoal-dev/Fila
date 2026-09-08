import FilaClient
import Then
import UIKit

/// Presets stay in the list when disabled so they can be reordered and enabled again.
final class AppearanceSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case browsing, systemFeatures, presets }
    private let preferences = AppPreferences.shared
    private var presets = AppPreferences.shared.presetOrder

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Appearance")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.do {
            $0.rowHeight = UITableView.automaticDimension
            $0.estimatedRowHeight = FilaUI.minimumTapTarget
            $0.allowsSelection = false
            $0.contentInset.bottom = SettingsFooter.spacing
        }
        setEditing(true, animated: false)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Section.presets.rawValue ? presets.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .browsing: String(localized: "Browsing")
        case .systemFeatures: String(localized: "System Features")
        case .presets: String(localized: "Places")
        case nil: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .systemFeatures:
            String(localized: "If a feature fails or stops responding, turn it off. The rest of Fila keeps working.")
        case .presets: String(localized: "Drag to reorder. Turn off a place to hide it.")
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let title: String
        let enabled: Bool
        let update: (Bool) -> Void
        switch Section(rawValue: indexPath.section) {
        case .presets:
            let preset = presets[indexPath.row]
            title = name(of: preset)
            enabled = preferences.isPresetEnabled(preset)
            update = { [preferences] in preferences.setPreset(preset, enabled: $0) }
            cell.showsReorderControl = true
        case .systemFeatures:
            title = String(localized: "Show Applications")
            enabled = preferences.showsApplications
            update = { [preferences] in
                preferences.showsApplications = $0
                NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
            }
        default:
            title = String(localized: "Show Hidden Files")
            enabled = preferences.showsHidden
            update = { [preferences] in
                preferences.showsHidden = $0
                NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
            }
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
        }, for: .valueChanged)
        cell.editingAccessoryView = toggle
        cell.accessoryView = toggle
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle { .none }

    override func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool { false }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == Section.presets.rawValue
    }

    override func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt source: IndexPath,
        toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
        guard proposed.section == source.section else {
            return IndexPath(row: proposed.section < source.section ? 0 : presets.count - 1, section: source.section)
        }
        return proposed
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let preset = presets.remove(at: source.row)
        presets.insert(preset, at: destination.row)
        preferences.presetOrder = presets
    }

    private func name(of preset: SidebarLocation.Position) -> String {
        switch preset {
        case .root:
            if case .local(.container) = FileSession.shared.hello?.backend { return String(localized: "Home") }
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
