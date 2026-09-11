import AlertController
import FilaCore
import UIKit

/// Add or edit one SMB share.
///
/// Every value is typed straight into its row — the server's address, the
/// share (typed, or chosen from what the server lists), the account — the
/// way Settings takes a Wi-Fi password. Save connects first — a wrong
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
        // A new share starts in account mode: most servers refuse a guest,
        // and a form that sent one by default read as "the server is broken".
        profile = existing?.profile ?? SMBProfile(name: "", host: "", share: "", username: "")
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
        tableView.register(FieldCell.self, forCellReuseIdentifier: "field")
        tableView.keyboardDismissMode = .interactive
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

    private func indexPath(of row: Row) -> IndexPath? {
        for section in Section.allCases {
            if let index = rows(in: section).firstIndex(of: row) {
                return IndexPath(row: index, section: section.rawValue)
            }
        }
        return nil
    }

    /// Redraws one row without touching the field the user is typing in:
    /// the rows that change while another is edited are never the edited one.
    private func reload(_ row: Row) {
        guard let indexPath = indexPath(of: row) else { return }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    private func fieldCell(for row: Row) -> FieldCell? {
        indexPath(of: row).flatMap { tableView.cellForRow(at: $0) as? FieldCell }
    }

    /// The Name row's placeholder is the share and server while no name is
    /// typed; it changes in place as they are typed, without a reload per key.
    private func reloadNamePlaceholder() {
        guard profile.name.isEmpty else { return }
        fieldCell(for: .name)?.setPlaceholder(field(for: .name).placeholder)
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
        switch row {
        case .chooseShare:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Choose Share…", bundle: bundle)
            content.textProperties.color = profile.host.isEmpty ? .secondaryLabel : .tintColor
            cell.contentConfiguration = content
            cell.accessoryView = nil
            cell.selectionStyle = profile.host.isEmpty ? .none : .default
            return cell
        case .guest:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Connect as Guest", bundle: bundle)
            cell.contentConfiguration = content
            cell.accessoryView = UISwitch().then {
                $0.isOn = profile.isGuest
                $0.addAction(UIAction { [weak self] action in
                    guard let self, let toggle = action.sender as? UISwitch else { return }
                    setGuest(toggle.isOn)
                }, for: .valueChanged)
            }
            cell.selectionStyle = .none
            return cell
        case .host, .port, .share, .domain, .username, .password, .name:
            let cell = tableView.dequeueReusableCell(withIdentifier: "field", for: indexPath) as! FieldCell
            cell.configure(field(for: row)) { [weak self] text in
                self?.apply(text, to: row)
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows(in: Section(rawValue: indexPath.section)!)[indexPath.row]
        switch row {
        case .chooseShare:
            guard !profile.host.isEmpty else { return }
            view.endEditing(true)
            chooseShare()
        case .guest, .host, .port, .share, .domain, .username, .password, .name:
            // Tapping the row's title focuses its field.
            (tableView.cellForRow(at: indexPath) as? FieldCell)?.beginEditing()
        }
    }

    /// The account put aside while Guest is on, so a switch flipped twice
    /// gives it back. The password is not touched by the switch at all:
    /// `passwordToStore` drops it only when the share is saved as guest.
    private var accountBeforeGuest: (username: String, domain: String?)?

    private func setGuest(_ guest: Bool) {
        view.endEditing(true)
        if guest {
            accountBeforeGuest = (profile.username ?? "", profile.domain)
            profile.username = nil
            profile.domain = nil
        } else {
            profile.username = accountBeforeGuest?.username ?? ""
            profile.domain = accountBeforeGuest?.domain
        }
        tableView.reloadSections([Section.account.rawValue], with: .automatic)
        refreshSaveButton()
    }

    // MARK: - Editing

    private func field(for row: Row) -> FieldCell.Configuration {
        switch row {
        case .host:
            return .init(
                title: String(localized: "Address", bundle: bundle),
                placeholder: String(localized: "Host name or IP address", bundle: bundle),
                text: profile.host,
                keyboard: .URL
            )
        case .port:
            return .init(
                title: String(localized: "Port", bundle: bundle),
                placeholder: String(SMBProfile.defaultPort),
                text: String(profile.port),
                keyboard: .numberPad
            )
        case .share:
            return .init(
                title: String(localized: "Share", bundle: bundle),
                placeholder: String(localized: "Shared folder", bundle: bundle),
                text: profile.share
            )
        case .domain:
            return .init(
                title: String(localized: "Domain", bundle: bundle),
                placeholder: String(localized: "Optional", bundle: bundle),
                text: profile.domain ?? ""
            )
        case .username:
            return .init(
                title: String(localized: "User Name", bundle: bundle),
                placeholder: String(localized: "Required", bundle: bundle),
                text: profile.username ?? ""
            )
        case .password:
            let stored: Bool
            switch password {
            case .none: stored = isStoredPasswordPresent
            case .some: stored = false
            }
            let typed: String
            switch password {
            case let .some(.some(value)): typed = value
            default: typed = ""
            }
            return .init(
                title: String(localized: "Password", bundle: bundle),
                // A stored password is never shown, not even as dots in the
                // field: the dots are a placeholder, and typing replaces it.
                placeholder: stored ? "••••••••" : String(localized: "Optional", bundle: bundle),
                text: typed,
                isSecure: true
            )
        case .name:
            let hasIdentity = !profile.host.isEmpty && !profile.share.isEmpty
            return .init(
                title: String(localized: "Name", bundle: bundle),
                placeholder: hasIdentity ? profile.displayName : String(localized: "Optional", bundle: bundle),
                text: profile.name
            )
        case .chooseShare, .guest:
            preconditionFailure("not a field")
        }
    }

    private func apply(_ text: String, to row: Row) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch row {
        case .host:
            let wasEmpty = profile.host.isEmpty
            profile.host = trimmed
            if wasEmpty != trimmed.isEmpty { reload(.chooseShare) }
            reloadNamePlaceholder()
        case .port:
            // Empty is the default; anything else must parse, or Save waits.
            profile.port = trimmed.isEmpty ? SMBProfile.defaultPort : (Int(trimmed) ?? 0)
        case .share:
            profile.share = trimmed
            reloadNamePlaceholder()
        case .domain:
            profile.domain = trimmed.isEmpty ? nil : trimmed
        case .username:
            profile.username = trimmed
        case .password:
            password = .some(text.isEmpty ? nil : text)
            // A field emptied after typing means "no password": the dots
            // that stood for the stored one must go, or the field says a
            // password is kept when Save is about to remove it. The cell is
            // being edited, so its placeholder is changed in place.
            fieldCell(for: .password)?.setPlaceholder(field(for: .password).placeholder)
        case .name:
            profile.name = trimmed
        case .chooseShare, .guest:
            break
        }
        refreshSaveButton()
    }

    /// Asks the server for its disk shares with the account as entered.
    private func chooseShare() {
        let profile = profile
        let candidatePassword = passwordForConnecting()
        work?.cancel()
        work = Task { @MainActor [weak self] in
            guard let self, let shell = BackendScreens.shell else { return }
            do {
                let shares = try await shell.withProgress(
                    title: String(localized: "Listing Shares…", bundle: bundle),
                    message: String(localized: "Looking up shares on \(profile.host).", bundle: bundle),
                    from: self
                ) { _ in
                    try await SMBShares.list(profile: profile, password: candidatePassword)
                }
                guard !Task.isCancelled else { return }
                present(shareChoice(shares), animated: true)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                shell.alert(
                    title: String(localized: "Unable to List Shares", bundle: bundle),
                    message: shell.failureText(for: error)
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
        view.endEditing(true)
        guard profile.validationFailure == nil else { return }
        // A share pointed elsewhere is a new entry with its own identity.
        var saving = profile
        if let existing, !existing.profile.namesSameShare(as: saving) {
            saving.id = UUID()
        }
        let candidatePassword = passwordForConnecting()
        work?.cancel()
        work = Task { @MainActor [weak self] in
            guard let self, let shell = BackendScreens.shell else { return }
            let probe = SMBFileService(profile: saving, password: candidatePassword, connectTimeout: 15, requestTimeout: 15)
            do {
                try await shell.withProgress(
                    title: String(localized: "Connecting…", bundle: bundle),
                    message: String(localized: "Connecting to \(saving.share) on \(saving.host).", bundle: bundle),
                    from: self
                ) { _ in
                    _ = try await probe.details(.root)
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

/// One labelled text field in a grouped row: the title leading, the value
/// typed trailing, the way Settings lays out a form.
private final class FieldCell: UITableViewCell {
    struct Configuration {
        var title: String
        var placeholder: String
        var text: String
        var keyboard: UIKeyboardType = .default
        var isSecure = false
    }

    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private let field = UITextField().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .right
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
        $0.spellCheckingType = .no
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.smartInsertDeleteType = .no
        $0.clearButtonMode = .whileEditing
        $0.returnKeyType = .done
    }

    private var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        field.addTarget(self, action: #selector(finishTextEntry(_:)), for: .editingDidEndOnExit)
        let row = UIStackView(arrangedSubviews: [titleLabel, field]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.large
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget - 2 * FilaUI.Spacing.small)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ configuration: Configuration, onChange: @escaping (String) -> Void) {
        titleLabel.text = configuration.title
        field.do {
            $0.text = configuration.text
            $0.placeholder = configuration.placeholder
            $0.accessibilityLabel = configuration.title
            $0.keyboardType = configuration.keyboard
            $0.isSecureTextEntry = configuration.isSecure
            $0.textContentType = configuration.isSecure ? .password : nil
        }
        self.onChange = onChange
    }

    func beginEditing() {
        field.becomeFirstResponder()
    }

    /// A placeholder that changes under a live field, without a reload that
    /// would take the keyboard away.
    func setPlaceholder(_ placeholder: String) {
        field.placeholder = placeholder
    }

    @objc private func changed() {
        onChange?(field.text ?? "")
    }

    @objc private func finishTextEntry(_ sender: UITextField) {
        sender.resignFirstResponder()
    }
}
