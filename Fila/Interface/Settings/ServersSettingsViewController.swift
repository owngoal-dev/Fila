import AlertController
import FilaBackendKit
import FilaBackendUI
import Then
import UIKit

/// Settings › Servers: every saved remote backend, grouped by the module
/// that owns it, with one row per module to add another.
///
/// Built entirely from `BackendConnectionSetup` registrations. Nothing
/// here knows what an SMB share is: a module for another protocol
/// registers a setup and gets its own group, its own *Add …* row and the
/// same edit and remove behaviour without a line of shell code. The
/// sidebar shows these backends as destinations and nothing else; this
/// is the only place they are added, edited or removed.
final class ServersSettingsViewController: UITableViewController {
    private enum Row {
        case server(BackendID)
        case add
    }

    private var setups: [BackendConnectionSetup] { BackendComposition.registry.connectionSetups }
    private var updates: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Servers")
        navigationItem.backButtonDisplayMode = .minimal
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        updates?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        // A share saved, renamed or removed from the setup sheet lands in
        // the registry and the sidebar model; this list follows the same
        // signal the sidebar does rather than asking the sheet to report.
        updates = Task { [weak self] in
            for await _ in BackendComposition.sidebar.updates() {
                guard let self, !Task.isCancelled else { return }
                tableView.reloadData()
            }
        }
    }

    // MARK: - Rows

    /// The backends `setup` owns, in registry order, then the row that
    /// adds one.
    private func rows(for setup: BackendConnectionSetup) -> [Row] {
        BackendComposition.registry.backends.filter { setup.owns($0.id) }.map { Row.server($0.id) } + [.add]
    }

    override func numberOfSections(in _: UITableView) -> Int {
        setups.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(for: setups[section]).count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        setups[section].listTitle
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == setups.count - 1 else { return nil }
        return String(localized: "Saved servers are listed under Servers in the sidebar. Removing one forgets its saved password and favorites; nothing on the server is changed.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let setup = setups[indexPath.section]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        switch rows(for: setup)[indexPath.row] {
        case let .server(id):
            // A content row, not a setting: the name the user gave the
            // server over where it actually points, so two shares with
            // the same nickname can still be told apart.
            var content = UIListContentConfiguration.subtitleCell()
            let root = BackendComposition.registry.backend(id)?.root
            content.text = root?.displayName
            content.secondaryText = root?.detail
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.image = root.flatMap(SidebarLocation.image(for:))
            content.imageProperties.maximumSize = CGSize(width: FilaUI.IconSize.file, height: FilaUI.IconSize.file)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
        case .add:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Add \(setup.title)…")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessoryType = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let setup = setups[indexPath.section]
        switch rows(for: setup)[indexPath.row] {
        case let .server(id): presentSetup(setup, editing: id)
        case .add: presentSetup(setup, editing: nil)
        }
    }

    override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let setup = setups[indexPath.section]
        guard case let .server(id) = rows(for: setup)[indexPath.row] else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, done in
            done(true)
            self?.confirmRemoval(of: id, through: setup)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    // MARK: - Actions

    /// The module's own screen, presented over this sheet: it carries its
    /// own Cancel and Save, so it cannot be pushed onto this stack.
    private func presentSetup(_ setup: BackendConnectionSetup, editing id: BackendID?) {
        guard let screen = setup.makeScreen(id) as? UIViewController else { return }
        presentAsFormSheet(screen)
    }

    private func confirmRemoval(of id: BackendID, through setup: BackendConnectionSetup) {
        guard let root = BackendComposition.registry.backend(id)?.root else { return }
        let name = root.displayName
        let alert = AlertViewController(
            title: String.LocalizationValue("Remove “\(name)”?"),
            message: String.LocalizationValue("Its saved password and favorites are forgotten. Nothing on the server is changed.")
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Remove"), attribute: .accent) {
                context.dispose {
                    do {
                        try setup.remove(id)
                    } catch {
                        FeedbackAlert.show(String(localized: "Unable to Remove Server"), message: FailureMessage.text(for: error))
                    }
                }
            }
        }
        present(alert, animated: true)
    }
}
