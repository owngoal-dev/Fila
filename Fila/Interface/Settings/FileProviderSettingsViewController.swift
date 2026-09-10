import AlertController
import FilaBackendUI
import FilaLog
import FilaProvider
import Then
import UIKit

/// Chooses the folder the Files app shows as "Fila"; the extension retains its own materialized URLs.
final class FileProviderSettingsViewController: UITableViewController {
    private enum Action { case choose, restore }

    private var location: ProviderLocation?
    private var status: String?
    private var actions: [Action] = [.choose, .restore]

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Files App Folder")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.contentInset.bottom = FilaUI.Spacing.settingsTail
        tableView.do {
            $0.estimatedRowHeight = FilaUI.minimumTapTarget
            $0.rowHeight = UITableView.automaticDimension
        }
        Task { [weak self] in
            let hello = await FileSession.shared.ready()
            guard let self else { return }
            // A sandboxed wrapper can browse only its own container, which the
            // extension cannot reach; the default is the only usable folder.
            guard case .local(.container) = hello.backend else { return }
            actions = [.restore]
            tableView.reloadWithAnimation()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadLocation()
    }

    static func groupURL() throws -> URL {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else {
            throw ProviderLocation.Failure.invalidConfiguration
        }
        return url
    }

    static func defaultDocuments() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    static func initializeDefault() throws {
        try ProviderLocation.initializeDefault(documentsURL: defaultDocuments(), in: groupURL())
    }

    private func reloadLocation() {
        do {
            location = try ProviderLocation.load(in: Self.groupURL())
            status = nil
            if let location, (try? location.resolve(in: Self.groupURL())) == nil {
                status = String(localized: "This folder is unavailable. Choose another folder or restore the default.")
            }
        } catch {
            status = String(localized: "The Files app folder could not be loaded. Reinstall Fila and try again.")
        }
        tableView.reloadWithAnimation()
    }

    override func numberOfSections(in _: UITableView) -> Int {
        2
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : actions.count
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = location?.isDefault == true
                ? String(localized: "Fila Documents")
                : String(localized: "Selected Folder")
            cell.selectionStyle = .none
        } else {
            switch actions[indexPath.row] {
            case .choose:
                content.text = String(localized: "Choose Folder…")
                cell.accessoryType = .disclosureIndicator
            case .restore:
                content.text = String(localized: "Restore Default")
            }
            content.textProperties.color = view.tintColor
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return [location?.displayPath, status].compactMap(\.self).joined(separator: "\n\n")
        }
        return String(localized: "Changing the folder does not move files. Unsaved edits in Files are discarded. The default is Fila's Documents folder.")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        do {
            switch actions[indexPath.row] {
            case .choose:
                let picker = SaveDestinationViewController(
                    message: String(localized: "Choose a folder both Fila and the Files app can open. The Files app cannot open folders that need root access."),
                    link: FileSession.shared.link
                ) { [weak self] url in
                    guard let self else { return }
                    do { try save(url, isDefault: false) }
                    catch { show(error) }
                }
                presentAsSheet(UINavigationController(rootViewController: picker))
            case .restore:
                try save(Self.defaultDocuments(), isDefault: true)
            }
        } catch { show(error) }
    }

    private func save(_ url: URL, isDefault: Bool) throws {
        location = try ProviderLocation.bind(to: url, isDefault: isDefault, in: Self.groupURL())
        reloadLocation()
        FileProviderDomain.reset()
        Toast.show(String(localized: "Files app folder updated"))
    }

    private func show(_ error: Error) {
        let message = if let failure = error as? ProviderLocation.Failure, case .recursiveLocation = failure {
            String(localized: "Fila cannot use this folder. Choose another folder.")
        } else {
            String(localized: "The folder could not be opened. Choose another folder.")
        }
        FilaLog.error("File Provider location change failed: \(error)")
        let alert = AlertViewController(title: String(localized: "Cannot Use Folder"), message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Close"), attribute: .accent) { context.dispose() }
        }
        present(alert, animated: true)
    }
}
