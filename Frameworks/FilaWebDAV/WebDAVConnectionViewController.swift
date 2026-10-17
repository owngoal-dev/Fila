import AlertController
import FilaCore
import UIKit

/// Add or edit one WebDAV server.
///
/// The server is one address, typed whole — the way Alist, Nextcloud and a
/// NAS all print it — then an optional account and a name. Save connects
/// first: a wrong password or an address that is not a WebDAV folder is an
/// ordinary card with the reason, and the server can still be saved
/// unreached. Editing the address of a saved profile makes a new backend:
/// bookmarks are paths on a filesystem, and this is another one.
final class WebDAVConnectionViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case server
        case account
        case name

        var title: String {
            let bundle = WebDAVBackend.bundle
            switch self {
            case .server: return String(localized: "Server", bundle: bundle)
            case .account: return String(localized: "Account", bundle: bundle)
            case .name: return String(localized: "Name", bundle: bundle)
            }
        }

        var rows: [Row] {
            switch self {
            case .server: [.address]
            case .account: [.username, .password]
            case .name: [.name]
            }
        }
    }

    private enum Row: Hashable {
        case address
        case username, password
        case name
    }

    /// An address, not a sentence: the same in every language.
    private static let exampleAddress = "http://192.168.1.2:5244/dav"

    private let module: FilaWebDAVModule
    private let existing: WebDAVBackend?
    private var profile: WebDAVProfile
    /// `.none` keeps the stored password; `.some` replaces it on save.
    private var password: String??
    private var isStoredPasswordPresent = false
    private var work: Task<Void, Never>?
    private var bundle: Bundle {
        WebDAVBackend.bundle
    }

    init(module: FilaWebDAVModule, existing: WebDAVBackend?) {
        self.module = module
        self.existing = existing
        profile = existing?.profile ?? WebDAVProfile(name: "", address: "")
        super.init(style: .insetGrouped)
        title = existing == nil
            ? String(localized: "Add WebDAV Server", bundle: bundle)
            : String(localized: "Edit WebDAV Server", bundle: bundle)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel", bundle: bundle)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            primaryAction: UIAction(title: String(localized: "Save", bundle: bundle)) { [weak self] _ in self?.save() },
        ).then {
            $0.style = .done
        }
        if let existing, let store = module.profileStore {
            isStoredPasswordPresent = (try? store.password(for: existing.profile)) != nil
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        work?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(FormFieldCell.self, forCellReuseIdentifier: "field")
        tableView.keyboardDismissMode = .interactive
        refreshSaveButton()
    }

    private func refreshSaveButton() {
        navigationItem.rightBarButtonItem?.isEnabled = profile.validationFailure == nil
    }

    // MARK: - Rows

    private func row(at indexPath: IndexPath) -> Row {
        Section(rawValue: indexPath.section)!.rows[indexPath.row]
    }

    private func fieldCell(for row: Row) -> FormFieldCell? {
        for section in Section.allCases {
            if let index = section.rows.firstIndex(of: row) {
                return tableView.cellForRow(at: IndexPath(row: index, section: section.rawValue)) as? FormFieldCell
            }
        }
        return nil
    }

    override func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section)!.rows.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)!.title
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .server:
            String(localized: "The full address of the WebDAV folder, such as http://192.168.1.2:5244/dav for Alist.", bundle: bundle)
        case .account:
            String(localized: "Leave the user name empty for a server without accounts. The password is kept in this device's keychain and never written anywhere else.", bundle: bundle)
        case .name:
            existing == nil
                ? nil
                : String(localized: "Changing the address creates a new sidebar item with its own favorites.", bundle: bundle)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = row(at: indexPath)
        let cell = tableView.dequeueReusableCell(withIdentifier: "field", for: indexPath) as! FormFieldCell
        cell.configure(field(for: row)) { [weak self] text in
            self?.apply(text, to: row)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // Tapping the row's title focuses its field.
        (tableView.cellForRow(at: indexPath) as? FormFieldCell)?.beginEditing()
    }

    // MARK: - Editing

    private func field(for row: Row) -> FormFieldCell.Configuration {
        switch row {
        case .address:
            return .init(
                title: String(localized: "Address", bundle: bundle),
                placeholder: Self.exampleAddress,
                text: profile.address,
                keyboard: .URL,
            )
        case .username:
            return .init(
                title: String(localized: "User Name", bundle: bundle),
                placeholder: String(localized: "Optional", bundle: bundle),
                text: profile.username ?? "",
            )
        case .password:
            let stored: Bool = switch password {
            case .none: isStoredPasswordPresent
            case .some: false
            }
            let typed: String = switch password {
            case let .some(.some(value)): value
            default: ""
            }
            return .init(
                title: String(localized: "Password", bundle: bundle),
                // A stored password is never shown, not even as dots in the
                // field: the dots are a placeholder, and typing replaces it.
                placeholder: stored ? "••••••••" : String(localized: "Optional", bundle: bundle),
                text: typed,
                isSecure: true,
            )
        case .name:
            return .init(
                title: String(localized: "Name", bundle: bundle),
                placeholder: profile.validationFailure == nil ? profile.displayName : String(localized: "Optional", bundle: bundle),
                text: profile.name,
            )
        }
    }

    private func apply(_ text: String, to row: Row) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch row {
        case .address:
            profile.address = trimmed
            // The Name row's placeholder follows the host while no name is
            // typed, changed in place without a reload per key.
            if profile.name.isEmpty {
                fieldCell(for: .name)?.setPlaceholder(field(for: .name).placeholder)
            }
        case .username:
            profile.username = trimmed.isEmpty ? nil : trimmed
        case .password:
            password = .some(text.isEmpty ? nil : text)
            // A field emptied after typing means "no password": the dots
            // that stood for the stored one must go.
            fieldCell(for: .password)?.setPlaceholder(field(for: .password).placeholder)
        case .name:
            profile.name = trimmed
        }
        refreshSaveButton()
    }

    /// The password a connection made from this form uses: the edited one,
    /// else what is stored for the profile being edited.
    private func passwordForConnecting() -> String? {
        if profile.username == nil {
            return nil
        }
        switch password {
        case let .some(value): return value
        case .none: return existing.flatMap { try? module.profileStore?.password(for: $0.profile) } ?? nil
        }
    }

    // MARK: - Saving

    private func save() {
        view.endEditing(true)
        guard profile.validationFailure == nil else { return }
        // A profile pointed elsewhere is a new entry with its own identity.
        var saving = profile
        if let existing, !existing.profile.namesSameServer(as: saving) {
            saving.id = UUID()
        }
        let candidatePassword = passwordForConnecting()
        work?.cancel()
        work = Task { @MainActor [weak self] in
            guard let self, let shell = BackendScreens.shell,
                  let probe = WebDAVFileService(profile: saving, password: candidatePassword, requestTimeout: 15)
            else { return }
            do {
                try await shell.withProgress(
                    title: String(localized: "Connecting…", bundle: bundle),
                    message: String(localized: "Connecting to \(saving.displayName).", bundle: bundle),
                    cancellable: true,
                    from: self,
                ) { _ in
                    let root = try await probe.details(.root)
                    guard root.kind == .directory else { throw WebDAVError.notWebDAV }
                }
                await probe.disconnect()
                guard !Task.isCancelled else { return }
                await commit(saving)
            } catch {
                await probe.disconnect()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                offerSavingUnreached(saving, error: error)
            }
        }
    }

    private func offerSavingUnreached(_ saving: WebDAVProfile, error: Error) {
        let reason = BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
        let bundle = bundle
        let alert = AlertViewController(
            title: .init(String(localized: "Unable to Connect", bundle: bundle)),
            message: .init(
                String(
                    localized: "\(reason)\n\nSave the server anyway? It can be opened later when it is reachable.",
                    bundle: bundle,
                ),
            ),
        ) { [weak self] context in
            context.addAction(title: .init(String(localized: "Cancel", bundle: bundle))) {
                context.dispose()
            }
            context.addAction(title: .init(String(localized: "Save Anyway", bundle: bundle)), attribute: .accent) {
                context.dispose {
                    Task { @MainActor in await self?.commit(saving) }
                }
            }
        }
        present(alert, animated: true)
    }

    /// The password to store with `saving`: an edit keeps the stored one
    /// unless the field was touched; a new identity copies what the old
    /// profile had, so a server moved to another address keeps its account.
    private func passwordToStore(for saving: WebDAVProfile) -> String?? {
        if saving.username == nil {
            return .some(nil)
        }
        if let existing, existing.profile.id != saving.id, password == nil {
            return .some(try? module.profileStore?.password(for: existing.profile) ?? nil)
        }
        return password
    }

    private func commit(_ saving: WebDAVProfile) async {
        do {
            let backend = try await module.save(saving, password: passwordToStore(for: saving), replacing: existing)
            let opens = existing == nil
            dismiss(animated: true) {
                guard opens else { return }
                BackendScreens.shell?.open(.root(of: backend.id))
            }
        } catch {
            BackendScreens.shell?.alert(
                title: String(localized: "Unable to Save Server", bundle: bundle),
                message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription,
            )
        }
    }
}
