import AlertController
import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// The choices behind *Compress…*: a name, the format with its zip level,
/// password and encryption, and where the archive goes. A form sheet on
/// iPad, a page sheet on iPhone.
final class CompressViewController: UIViewController {
    struct Choice {
        var name: String
        var directory: String
        var options: ArchiveOptions
    }

    private enum Section: Int, CaseIterable { case name, options, destination }
    private enum Row: Hashable { case name, format, level, password, encryption, destination }

    private var name: String
    private var directory: String
    private let itemCount: Int
    private let link: DaemonLink
    private var format: ArchiveFormat = .zip
    private var level: ZipCompression = .balanced
    private var encryption: ZipEncryption = .aes256
    private var password = ""
    private let confirm: (Choice) -> Void

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    init(suggestedName: String, directory: String, itemCount: Int, link: DaemonLink, confirm: @escaping (Choice) -> Void) {
        name = suggestedName
        self.directory = directory
        self.itemCount = itemCount
        self.link = link
        self.confirm = confirm
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Compress")
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Compress"), style: .done, target: self, action: #selector(commit))
        preferredContentSize = CGSize(width: 440, height: 560)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Wrapped in its navigation controller and sized for the device.
    static func present(
        from presenter: UIViewController, suggestedName: String, directory: String, itemCount: Int, link: DaemonLink,
        confirm: @escaping (Choice) -> Void
    ) {
        let form = CompressViewController(suggestedName: suggestedName, directory: directory, itemCount: itemCount, link: link, confirm: confirm)
        let navigation = UINavigationController(rootViewController: form)
        if presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .formSheet
            presenter.present(navigation, animated: true)
        } else {
            presenter.presentAsSheet(navigation)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped).with {
            $0.headerMode = .supplementary
            $0.footerMode = .supplementary
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        buildDataSource()
        apply()
    }

    private func buildDataSource() {
        let field = UICollectionView.CellRegistration<TextFieldCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(text: self.name, placeholder: String(localized: "Archive name"), suffix: "." + self.format.filenameExtension) { self.name = $0 }
        }
        let choice = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            cell.accessories = []
            switch row {
            case .format:
                content.text = String(localized: "Format")
                cell.accessories = [self.menuAccessory(ArchiveFormat.allCases, selected: self.format, title: Self.title(for:)) { self.format = $0 }]
            case .level:
                content.text = String(localized: "Compression")
                cell.accessories = [self.menuAccessory(ZipCompression.allCases, selected: self.level, title: Self.title(for:)) { self.level = $0 }]
            case .encryption:
                content.text = String(localized: "Encryption")
                cell.accessories = [self.menuAccessory(ZipEncryption.allCases, selected: self.encryption, title: Self.title(for:)) { self.encryption = $0 }]
            case .password:
                content.text = String(localized: "Password")
                content.secondaryText = self.password.isEmpty ? String(localized: "None") : String(repeating: "•", count: 8)
                cell.accessories = [.disclosureIndicator()]
            case .destination:
                content.text = String(localized: "Save To")
                content.secondaryText = self.directory
                content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                cell.accessories = [.disclosureIndicator()]
            case .name:
                return
            }
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = Section(rawValue: indexPath.section) == .options ? String(localized: "Options") : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.footerText(for: indexPath.section)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, row in
            row == .name
                ? collection.dequeueConfiguredReusableCell(using: field, for: indexPath, item: row)
                : collection.dequeueConfiguredReusableCell(using: choice, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collection, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// A pop-up button on the trailing edge. `changesSelectionAsPrimaryAction`
    /// draws its own up/down indicator; a second chevron here doubled it.
    private func menuAccessory<Value: Equatable>(
        _ values: [Value], selected: Value, title: @escaping (Value) -> String, choose: @escaping (Value) -> Void
    ) -> UICellAccessory {
        let button = UIButton(configuration: .plain()).then {
            $0.menu = UIMenu(children: values.map { value in
                UIAction(title: title(value), state: value == selected ? .on : .off) { [weak self] _ in
                    choose(value)
                    self?.apply()
                }
            })
            $0.showsMenuAsPrimaryAction = true
            $0.changesSelectionAsPrimaryAction = true
            $0.configuration?.baseForegroundColor = .secondaryLabel
        }
        return .customView(configuration: .init(customView: button, placement: .trailing()))
    }

    private func footerText(for section: Int) -> String? {
        switch Section(rawValue: section) {
        case .options where format != .zip:
            return String(localized: "Only ZIP archives can be protected with a password.")
        case .options where !password.isEmpty:
            return encryption == .aes256
                ? String(localized: "AES-256 provides strong encryption, but some older tools cannot open these archives.")
                : String(localized: "ZipCrypto offers broad compatibility but weak password protection.")
        case .destination:
            return String(localized: "The archive will be created in this folder.")
        default:
            return nil
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.name], toSection: .name)
        var options: [Row] = [.format]
        if format == .zip {
            options += password.isEmpty ? [.level, .password] : [.level, .password, .encryption]
        }
        snapshot.appendItems(options, toSection: .options)
        snapshot.appendItems([.destination], toSection: .destination)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
        // The footer reads the live state; the snapshot does not carry it.
        for view in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
            guard let cell = view as? UICollectionViewListCell, var content = cell.contentConfiguration as? UIListContentConfiguration,
                  let section = collectionView.indexPath(forSupplementaryView: view)?.section else { continue }
            content.text = footerText(for: section)
            cell.contentConfiguration = content
        }
    }

    // MARK: - Password

    /// Typed twice, the way the Web UI sets its password: a typo in a
    /// password nobody can see is an archive nobody can open.
    private func promptPassword() {
        let first = AlertInputViewController(
            title: "Set Password",
            message: "Enter a password for the archive. Leave it empty for no password.",
            placeholder: "Password",
            text: "",
            doneButtonText: "Next"
        ) { [weak self] entered in
            guard let self else { return }
            guard !entered.isEmpty else {
                self.password = ""
                self.apply()
                return
            }
            let second = AlertInputViewController(
                title: "Confirm Password",
                message: "Enter the password again.",
                placeholder: "Password",
                text: "",
                doneButtonText: "Set"
            ) { [weak self] confirmed in
                guard let self else { return }
                guard confirmed == entered else {
                    let alert = AlertViewController(title: "Passwords Do Not Match", message: "The password was not changed. Try again.") { context in
                        context.allowSimpleDispose()
                        context.addAction(title: "OK", attribute: .accent) { context.dispose() }
                    }
                    self.present(alert, animated: true)
                    return
                }
                self.password = confirmed
                self.apply()
            }
            self.present(second, animated: true)
        }
        present(first, animated: true)
    }

    private func promptDestination() {
        let picker = SaveDestinationViewController(directory: URL(fileURLWithPath: directory, isDirectory: true), link: link) { [weak self] url in
            self?.directory = url.path
            self?.apply()
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func commit() {
        view.endEditing(true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".", trimmed != ".." else {
            FeedbackAlert.show(String(localized: "Invalid Name"), message: String(localized: "Enter an archive name without slashes. “.” and “..” cannot be used."))
            return
        }
        let choice = Choice(
            name: trimmed + "." + format.filenameExtension,
            directory: directory,
            options: ArchiveOptions(
                format: format,
                zipCompression: level,
                encryption: encryption,
                password: format == .zip && !password.isEmpty ? password : nil
            )
        )
        dismiss(animated: true) { self.confirm(choice) }
    }

    // MARK: - Titles

    private static func title(for format: ArchiveFormat) -> String {
        switch format {
        case .zip: return "ZIP"
        case .tarZstd: return "TAR + Zstandard"
        case .tar: return "TAR"
        case .tarGzip: return "TAR + Gzip"
        case .tarBzip2: return "TAR + Bzip2"
        case .tarXz: return "TAR + XZ"
        case .tarLzma: return "TAR + LZMA"
        case .tarLzip: return "TAR + Lzip"
        case .tarLz4: return "TAR + LZ4"
        }
    }

    private static func title(for level: ZipCompression) -> String {
        switch level {
        case .balanced: return String(localized: "Balanced")
        case .smallest: return String(localized: "Smallest")
        case .store: return String(localized: "Uncompressed")
        }
    }

    private static func title(for encryption: ZipEncryption) -> String {
        switch encryption {
        case .aes256: return "AES-256"
        case .zipCrypto: return "ZipCrypto"
        }
    }
}

extension CompressViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .password, .destination: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        view.endEditing(true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .password: promptPassword()
        case .destination: promptDestination()
        default: break
        }
    }
}

/// One text field in a grouped row, with the fixed suffix — the extension
/// the format decides — drawn after it.
private final class TextFieldCell: UICollectionViewListCell {
    private let field = UITextField()
    private let suffixLabel = UILabel()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.clearButtonMode = .whileEditing
            $0.returnKeyType = .done
            $0.addTarget(self, action: #selector(changed), for: .editingChanged)
            $0.addTarget(self, action: #selector(finishTextEntry(_:)), for: .editingDidEndOnExit)
        }
        suffixLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [field, suffixLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget - 2 * FilaUI.Spacing.small)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, placeholder: String, suffix: String, onChange: @escaping (String) -> Void) {
        field.text = text
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        suffixLabel.text = suffix
        self.onChange = onChange
    }

    @objc private func changed() { onChange?(field.text ?? "") }
    @objc private func finishTextEntry(_ sender: UITextField) { sender.resignFirstResponder() }
}
