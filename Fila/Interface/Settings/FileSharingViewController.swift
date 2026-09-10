import AlertController
import CoreImage.CIFilterBuiltins
import FilaBackendUI
import FilaRemote
import SnapKit
import Then
import UIKit

/// Sharing state comes from the server; credential edits apply on its next start.
final class FileSharingViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case server, credentials, background, connections, qrCode
    }

    private enum Row: Hashable {
        case status
        case failure(String)
        case userName, password, port, sharedFolder, keepsRunning
        case connection(UUID)
        case noConnections, clearConnections
        case qrCode(String)
    }

    private static let visibleConnectionCount = 50
    private static let folderIcon = UIImage(named: "SharingFolder")
    /// The same folder, drained of colour: off is grey, on is the real icon.
    private static let folderIconOff: UIImage? = {
        guard let icon = folderIcon, let input = CIImage(image: icon) else { return nil }
        let filter = CIFilter.photoEffectTonal()
        filter.inputImage = input
        guard let output = filter.outputImage,
              let rendered = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: icon.scale, orientation: .up)
    }()

    private let center = FileSharingServer.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "File Sharing")
        view.backgroundColor = .systemGroupedBackground

        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped).with {
            $0.headerMode = .supplementary
            $0.footerMode = .supplementary
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.delegate = self
        collectionView.contentInset.bottom = FilaUI.Spacing.settingsTail
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        buildDataSource()
        apply()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverChanged),
            name: .filaRemoteServerChanged,
            object: nil
        )
    }

    @objc private func serverChanged() {
        apply()
    }

    private func buildDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        let qrCell = UICollectionView.CellRegistration<QRCodeCell, Row> { cell, _, row in
            guard case let .qrCode(address) = row else { return }
            cell.show(address)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.footer)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, row in
            if case .qrCode = row {
                return collection.dequeueConfiguredReusableCell(using: qrCell, for: indexPath, item: row)
            }
            return collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collection, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            }
            return collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let addresses = center.addresses
        snapshot.appendSections(
            addresses.isEmpty ? [.server, .credentials, .background, .connections] : Section.allCases
        )
        var server: [Row] = [.status]
        if let failure = center.startFailure {
            server.append(.failure(failure))
        }
        snapshot.appendItems(server, toSection: .server)
        snapshot.appendItems([.userName, .password, .port, .sharedFolder], toSection: .credentials)
        snapshot.appendItems([.keepsRunning], toSection: .background)
        let entries = center.log.prefix(Self.visibleConnectionCount)
        snapshot.appendItems(
            entries.isEmpty ? [.noConnections] : entries.map { .connection($0.id) } + [.clearConnections],
            toSection: .connections
        )
        if let first = addresses.first {
            // The first address is the first non-cellular, non-VPN interface —
            // Wi-Fi on a phone. A second interface is rare and typed by hand.
            snapshot.appendItems([.qrCode(first)], toSection: .qrCode)
        }
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(
            [.status, .userName, .password, .port, .sharedFolder].filter { previous.contains($0) }
        )
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The listener read its credentials and port when it started; while it
    /// is up the rows show a lock rather than pretending an edit would apply.
    private var credentialsLocked: Bool {
        center.isRunning || center.isStarting
    }

    private var credentialAccessory: UICellAccessory {
        guard credentialsLocked else { return .disclosureIndicator() }
        let lock = UIImageView(image: UIImage(systemName: "lock.fill")).then {
            $0.tintColor = .tertiaryLabel
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        }
        return .customView(configuration: .init(customView: lock, placement: .trailing()))
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.numberOfLines = 0
        cell.accessories = []
        switch row {
        case .status:
            content = UIListContentConfiguration.subtitleCell()
            content.text = center.isRunning ? String(localized: "Sharing Is On") : String(localized: "Sharing Is Off")
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.textProperties.numberOfLines = 0
            content.secondaryText = center.isRunning
                ? (center.addresses.isEmpty
                    ? String(localized: "No network address yet.")
                    : center.addresses.joined(separator: "\n"))
                : String(localized: "Ready to share with devices on your network.")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.textToSecondaryTextVerticalPadding = FilaUI.Spacing.compact
            content.image = center.isRunning ? Self.folderIcon : Self.folderIconOff
            content.imageProperties.maximumSize = CGSize(width: FilaUI.IconSize.hero, height: FilaUI.IconSize.hero)
            content.imageProperties.reservedLayoutSize = content.imageProperties.maximumSize
            content.imageToTextPadding = FilaUI.Spacing.large
            content.directionalLayoutMargins.top = FilaUI.Spacing.large
            content.directionalLayoutMargins.bottom = FilaUI.Spacing.large
            let toggle = UISwitch()
            // On while starting too, or the switch flicks off and on again
            // between the tap and the listener coming up.
            toggle.isOn = center.isRunning || center.isStarting
            toggle.accessibilityLabel = String(localized: "File Sharing")
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                if toggle.isOn {
                    center.start()
                } else {
                    center.stop()
                }
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        case let .failure(text):
            content.text = text
            content.textProperties.color = .systemRed
        case .userName:
            content.text = String(localized: "User Name")
            content.secondaryText = AppPreferences.shared.serverUsername
            cell.accessories = [credentialAccessory]
        case .password:
            content.text = String(localized: "Password")
            content.secondaryText = AppPreferences.shared.serverPassword
            content.secondaryTextProperties.font = FilaUI.Font.monospacedValue
            cell.accessories = [credentialAccessory]
        case .port:
            content.text = String(localized: "Port")
            content.secondaryText = String(AppPreferences.shared.serverPort)
            cell.accessories = [credentialAccessory]
        case .sharedFolder:
            content.text = String(localized: "Shared Folder")
            content.secondaryText = AppPreferences.shared.serverRoot
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            cell.accessories = [credentialAccessory]
        case .keepsRunning:
            content.text = String(localized: "Keep Sharing in Background")
            let toggle = UISwitch()
            toggle.isOn = AppPreferences.shared.keepsServerRunningInBackground
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { [weak toggle] _ in
                guard let toggle else { return }
                AppPreferences.shared.keepsServerRunningInBackground = toggle.isOn
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        case let .connection(identifier):
            content.text = center.log.first { $0.id == identifier }?.text
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        case .noConnections:
            content.text = String(localized: "No devices have connected yet.")
            content.textProperties.color = .secondaryLabel
        case .clearConnections:
            content.text = String(localized: "Clear Connections")
            content.textProperties.color = .systemRed
        case .qrCode:
            return
        }
        cell.contentConfiguration = content
    }

    private func edit(_ row: Row) {
        let title: String.LocalizationValue
        let message: String.LocalizationValue
        let placeholder: String.LocalizationValue
        let value: String
        switch row {
        case .userName:
            title = "User Name"
            message = "Anyone connecting must enter this name."
            placeholder = "User Name"
            value = AppPreferences.shared.serverUsername
        case .password:
            title = "Password"
            message = "Anyone connecting must enter this password. Leave it empty to generate a new one."
            placeholder = "Password"
            value = AppPreferences.shared.serverPassword
        case .port:
            title = "Port"
            message = "Enter a port from 1024 to 65535."
            placeholder = "Port"
            value = String(AppPreferences.shared.serverPort)
        default:
            return
        }
        let alert = AlertInputViewController(
            title: title,
            message: message,
            placeholder: placeholder,
            text: value,
            doneButtonText: String.LocalizationValue("Save")
        ) { [weak self] text in
            switch row {
            case .userName: AppPreferences.shared.serverUsername = text
            case .password: AppPreferences.shared.serverPassword = text
            case .port:
                guard let port = UInt16(text), port >= 1024 else { return }
                AppPreferences.shared.serverPort = port
            default: return
            }
            self?.apply()
        }
        present(alert, animated: true)
    }

    /// The same folder panel as Save To, opened at the current root so the
    /// default is one tap away and anything else is a walk from there.
    private func chooseSharedFolder() {
        let picker = SaveDestinationViewController(
            message: String(localized: "Devices on the network see only what is inside this folder."),
            link: FileSession.shared.link
        ) { [weak self] url in
            AppPreferences.shared.serverRoot = url.path
            self?.apply()
        }
        presentAsSheet(UINavigationController(rootViewController: picker))
    }

    private static func header(for section: Section) -> String? {
        switch section {
        case .server: nil
        case .credentials: String(localized: "Connection Settings")
        case .background: String(localized: "Background Sharing")
        case .connections: String(localized: "Connections")
        case .qrCode: String(localized: "Scan to Connect")
        }
    }

    private static func footer(for section: Section) -> String? {
        switch section {
        case .server:
            String(localized: "Open an address in a web browser on the same network. Anyone with the password can reach everything inside the shared folder. The connection is not encrypted, so use it only on a network you trust.")
        case .credentials:
            String(localized: "Changes take effect the next time you start sharing.")
        case .background:
            String(localized: "iOS allows only a short time to finish transfers after you leave Fila. Sharing then stops and connected devices disconnect.")
        case .connections: nil
        case .qrCode:
            String(localized: "Point another device's camera at the code to open Fila in its browser.")
        }
    }
}

extension FileSharingViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .userName, .password, .port, .sharedFolder: !credentialsLocked
        case .clearConnections: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .userName, .password, .port: edit(row)
        case .sharedFolder: chooseSharedFolder()
        case .clearConnections: center.clearLog()
        default: break
        }
    }
}

/// One centred QR code with its address underneath. Black on white in both
/// appearances: a code that follows dark mode is a code a camera cannot read.
private final class QRCodeCell: UICollectionViewListCell {
    private static let side: CGFloat = 200

    private let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.layer.magnificationFilter = .nearest
        $0.backgroundColor = .white
        $0.layer.cornerRadius = FilaUI.Spacing.small
        $0.layer.masksToBounds = true
    }

    private let label = UILabel().then {
        $0.font = FilaUI.Font.monospacedFootnote
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 0
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(imageView)
        contentView.addSubview(label)
        imageView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.centerX.equalToSuperview()
            make.width.height.equalTo(Self.side)
        }
        label.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(FilaUI.Spacing.medium)
            make.leading.trailing.equalToSuperview().inset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().inset(FilaUI.Spacing.large)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func show(_ address: String) {
        label.text = address
        imageView.image = Self.code(for: address)
    }

    private static func code(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Quiet zone: the generator draws none, and a scanner needs one.
        let padded = output.extent.insetBy(dx: -4, dy: -4)
        let transform = CGAffineTransform(
            scaleX: side * UIScreen.main.scale / padded.width,
            y: side * UIScreen.main.scale / padded.height
        )
        // Nearest sampling keeps module edges hard at a fractional scale.
        let scaled = output.samplingNearest().transformed(by: transform)
        guard let rendered = CIContext().createCGImage(scaled, from: padded.applying(transform)) else { return nil }
        return UIImage(cgImage: rendered, scale: UIScreen.main.scale, orientation: .up)
    }
}
