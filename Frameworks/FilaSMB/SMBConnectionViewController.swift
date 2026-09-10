import AlertController
import FilaCore
import UIKit

/// Add or edit one SMB share.
///
/// Value rows, each edited through the one input card, the way the sharing
/// settings are: the server's address, the share (typed, or chosen from
/// what the server lists), the account. Save connects first — a wrong
/// password or a missing share is an ordinary card with the server's
/// reason, and the share can still be saved unreached — then registers
/// the backend and opens it. Editing the address or the share of a saved
/// profile makes a new backend: bookmarks are paths on a filesystem, and
/// this is another one.
final class SMBConnectionViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case server
        case account
        case name

        var title: String {
            let bundle = SMBBackend.bundle
            switch self {
            case .server: return String(localized: "Server", bundle: bundle)
            case .account: return String(localized: "Account", bundle: bundle)
            case .name: return String(localized: "Name", bundle: bundle)
            }
        }
    }

    private enum Row: Hashable {
        case host, port, share, chooseShare
        case guest, domain, username, password
        case name
    }

    private let module: FilaSMBModule
    private let existing: SMBBackend?
    private var profile: SMBProfile
    /// `.none` keeps the stored password; `.some` replaces it on save.
    private var password: String?? = nil
    private var isStoredPasswordPresent = false
    private var work: Task<Void, Never>?
    private var bundle: Bundle { SMBBackend.bundle }

    init(module: FilaSMBModule, existing: SMBBackend?) {
        self.module = module
        self.existing = existing
        profile = existing?.profile ?? SMBProfile(name: "", host: "", share: "")
        super.init(style: .insetGrouped)
        title = existing == nil
            ? String(localized: "Add SMB Share", bundle: bundle)
            : String(localized: "Edit SMB Share", bundle: bundle)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel", bundle: bundle)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            primaryAction: UIAction(title: String(localized: "Save", bundle: bundle)) { [weak self] _ in self?.save() }
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        refreshSaveButton()
    }

    private func refreshSaveButton() {
        navigationItem.rightBarButtonItem?.isEnabled = profile.validationFailure == nil
    }

    // MARK: - Rows

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .server: return [.host, .port, .share, .chooseShare]
        case .account: return profile.isGuest ? [.guest] : [.guest, .domain, .username, .password]
        case .name: return [.name]
        }
    }

    override func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: Section(rawValue: section)!).count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)!.title
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .server:
            return String(localized: "Uses SMB 2 on port 445. SMB 1 is not supported.", bundle: bundle)
        case .account:
            return profile.isGuest
                ? String(localized: "Guest access has no username or password. Servers that require an account will refuse it.", bundle: bundle)
                : String(localized: "The password is kept in this device's keychain and never written anywhere else.", bundle: bundle)
        case .name:
            return existing == nil
                ? nil
                : String(localized: "Changing the server or share creates a new sidebar item with its own favorites.", bundle: bundle)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows(in: Section(rawValue: indexPath.section)!)[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        switch row {
        case .host:
            content.text = String(localized: "Address", bundle: bundle)
            content.secondaryText = profile.host
        case .port:
            content.text = String(localized: "Port", bundle: bundle)
            content.secondaryText = String(profile.port)
        case .share:
            content.text = String(localized: "Share", bundle: bundle)
            content.secondaryText = profile.share
        case .chooseShare:
            content = .cell()
            content.text = String(localized: "Choose Share…", bundle: bundle)
            content.textProperties.color = profile.host.isEmpty ? .secondaryLabel : .tintColor
            cell.selectionStyle = profile.host.isEmpty ? .none : .default
        case .guest:
            content = .cell()
            content.text = String(localized: "Connect as Guest", bundle: bundle)
            let toggle = UISwitch()
            toggle.isOn = profile.isGuest
            toggle.addAction(UIAction { [weak self] action in
                guard let self, let toggle = action.sender as? UISwitch else { return }
                setGuest(toggle.isOn)
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .domain:
            content.text = String(localized: "Domain", bundle: bundle)
            content.secondaryText = profile.domain ?? ""
        case .username:
            content.text = String(localized: "User Name", bundle: bundle)
            content.secondaryText = profile.username ?? ""
        case .password:
            content.text = String(localized: "Password", bundle: bundle)
            let present: Bool
            switch password {
            case .none: present = isStoredPasswordPresent
            case let .some(value): present = value?.isEmpty == false
            }
            content.secondaryText = present ? "••••••••" : ""
        case .name:
            content.text = String(localized: "Name", bundle: bundle)
            content.secondaryText = profile.name.isEmpty ? profile.displayName : profile.name
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows(in: Section(rawValue: indexPath.section)!)[indexPath.row]
        switch row {
        case .chooseShare:
            guard !profile.host.isEmpty else { return }
            chooseShare()
        case .guest:
            break
        default:
            edit(row)
        }
    }

    private func setGuest(_ guest: Bool) {
        if guest {
            profile.username = nil
            profile.domain = nil
            password = .some(nil)
        } else {
            profile.username = ""
        }
        tableView.reloadSections([Section.account.rawValue], with: .automatic)
        refreshSaveButton()
    }

    // MARK: - Editing

    /// AlertController resolves a `String.LocalizationValue` against the
    /// app's bundle, where none of this module's strings live, so every
    /// card here is given text already resolved from the module's own
    /// catalogue.
    private func edit(_ row: Row) {
        let title: String
        let message: String
        let value: String
        switch row {
        case .host:
            title = String(localized: "Address", bundle: bundle)
            message = String(localized: "The server's host name or IP address.", bundle: bundle)
            value = profile.host
        case .port:
            title = String(localized: "Port", bundle: bundle)
            message = String(localized: "Usually 445. Change it only if the server uses another port.", bundle: bundle)
            value = String(profile.port)
        case .share:
            title = String(localized: "Share", bundle: bundle)
            message = String(localized: "The name of the shared folder on the server.", bundle: bundle)
            value = profile.share
        case .domain:
            title = String(localized: "Domain", bundle: bundle)
            message = String(
                localized: "The account's domain or workgroup. Leave it empty unless the server needs one.",
                bundle: bundle
            )
            value = profile.domain ?? ""
        case .username:
            title = String(localized: "User Name", bundle: bundle)
            message = String(localized: "The user name for this share.", bundle: bundle)
            value = profile.username ?? ""
        case .password:
            title = String(localized: "Password", bundle: bundle)
            message = String(localized: "The password for this share is kept in the keychain.", bundle: bundle)
            value = ""
        case .name:
            title = String(localized: "Name", bundle: bundle)
            message = String(
                localized: "The name shown in the sidebar. Leave empty to use the share and server names.",
                bundle: bundle
            )
            value = profile.name
        case .chooseShare, .guest:
            return
        }
        let alert = AlertInputViewController(
            title: title,
            message: message,
            placeholder: "",
            text: value,
            cancelButtonText: String(localized: "Cancel", bundle: bundle),
            doneButtonText: String(localized: "Done", bundle: bundle)
        ) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            switch row {
            case .host: profile.host = trimmed
            case .port: profile.port = Int(trimmed) ?? SMBProfile.defaultPort
            case .share: profile.share = trimmed
            case .domain: profile.domain = trimmed.isEmpty ? nil : trimmed
            case .username: profile.username = trimmed
            case .password: password = .some(text.isEmpty ? nil : text)
            case .name: profile.name = trimmed
            case .chooseShare, .guest: break
            }
            tableView.reloadData()
            refreshSaveButton()
        }
        present(alert, animated: true)
    }

    /// Asks the server for its disk shares with the account as entered.
    private func chooseShare() {
        let profile = profile
        let candidatePassword = passwordForConnecting()
        work?.cancel()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let card = BackendScreens.shell?.progressCard(
                title: String(localized: "Listing Shares…", bundle: bundle),
                message: String(localized: "Looking up shares on \(profile.host).", bundle: bundle),
                from: self
            )
            do {
                let shares = try await SMBShares.list(profile: profile, password: candidatePassword)
                card?.dismiss()
                guard !Task.isCancelled else { return }
                present(shareChoice(shares), animated: true)
            } catch {
                card?.dismiss()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                BackendScreens.shell?.alert(
                    title: String(localized: "Unable to List Shares", bundle: bundle),
                    message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
                )
            }
        }
    }

    private func shareChoice(_ shares: [String]) -> UIViewController {
        AlertViewController(
            title: String(localized: "Choose Share", bundle: bundle),
            message: shares.isEmpty
                ? String(
                    localized: "This account has no listed shares. Type the share name instead.",
                    bundle: bundle
                )
                : String(localized: "Shared folders available to this account.", bundle: bundle)
        ) { [weak self] context in
            for share in shares.prefix(24) {
                // The card looks a plain string up as a key; a share the
                // server happened to call "Cancel" would be rendered as the
                // app's word for it. Cosmetic, and the package offers no
                // way around it.
                context.addAction(title: share) {
                    context.dispose {
                        self?.profile.share = share
                        self?.tableView.reloadData()
                        self?.refreshSaveButton()
                    }
                }
            }
            context.addAction(title: String(localized: "Cancel", bundle: SMBBackend.bundle)) {
                context.dispose()
            }
        }
    }

    /// The password a connection made from this form uses: the edited
    /// one, else what is stored for the profile being edited.
    private func passwordForConnecting() -> String? {
        if profile.isGuest { return nil }
        switch password {
        case let .some(value): return value
        case .none: return existing.flatMap { try? module.profileStore?.password(for: $0.profile) } ?? nil
        }
    }

    // MARK: - Saving

    private func save() {
        guard profile.validationFailure == nil else { return }
        // A share pointed elsewhere is a new entry with its own identity.
        var saving = profile
        if let existing, !existing.profile.namesSameShare(as: saving) {
            saving.id = UUID()
        }
        let candidatePassword = passwordForConnecting()
        work?.cancel()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let card = BackendScreens.shell?.progressCard(
                title: String(localized: "Connecting…", bundle: bundle),
                message: String(localized: "Connecting to \(saving.share) on \(saving.host).", bundle: bundle),
                from: self
            )
            let probe = SMBFileService(profile: saving, password: candidatePassword, connectTimeout: 15, requestTimeout: 15)
            do {
                _ = try await probe.details(.root)
                await probe.disconnect()
                card?.dismiss()
                guard !Task.isCancelled else { return }
                await commit(saving)
            } catch {
                await probe.disconnect()
                card?.dismiss()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                offerSavingUnreached(saving, error: error)
            }
        }
    }

    private func offerSavingUnreached(_ saving: SMBProfile, error: Error) {
        let reason = BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
        let bundle = bundle
        let alert = AlertViewController(
            title: String(localized: "Unable to Connect", bundle: bundle),
            message: String(
                localized: "\(reason)\n\nSave the share anyway? It can be opened later when the server is reachable.",
                bundle: bundle
            )
        ) { [weak self] context in
            context.addAction(title: String(localized: "Cancel", bundle: bundle)) {
                context.dispose()
            }
            context.addAction(title: String(localized: "Save Anyway", bundle: bundle), attribute: .accent) {
                context.dispose {
                    Task { @MainActor in await self?.commit(saving) }
                }
            }
        }
        present(alert, animated: true)
    }

    /// The password to store with `saving`: an edit keeps the stored one
    /// unless the field was touched; a new identity copies what the old
    /// profile had, so a share moved to another server keeps its account.
    private func passwordToStore(for saving: SMBProfile) -> String?? {
        if saving.isGuest { return .some(nil) }
        if let existing, existing.profile.id != saving.id, password == nil {
            return .some(try? module.profileStore?.password(for: existing.profile) ?? nil)
        }
        return password
    }

    private func commit(_ saving: SMBProfile) async {
        do {
            let backend = try await module.save(saving, password: passwordToStore(for: saving), replacing: existing)
            let opens = existing == nil
            dismiss(animated: true) {
                guard opens else { return }
                BackendScreens.shell?.open(.root(of: backend.id))
            }
        } catch {
            BackendScreens.shell?.alert(
                title: String(localized: "Unable to Save Share", bundle: bundle),
                message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
            )
        }
    }
}
