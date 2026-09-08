import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Native grouped settings with direct feature, diagnostic and about destinations.
final class SettingsViewController: UIViewController {
    private enum Page { case main, behavior, protection, about }
    private let page: Page

    convenience init() { self.init(page: .main) }

    private init(page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
        navigationItem.backButtonDisplayMode = .minimal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private enum Section: Hashable {
        case groups
        case browsing
        case fileOperations
        case systemFeatures
        case scripts
        case guardOverride
        case branding
        case diagnostics
        case about
    }

    /// One case per row, so the snapshot is a list of facts rather than a list
    /// of view models. Everything a row draws is read from `AppPreferences` or
    /// from `hello` at configure time, which is why flipping a switch needs no
    /// mirrored copy of the setting to keep in step.
    private enum Row: Hashable {
        case recordsRecents
        case launchLocation
        case usesTrash
        case runsPrograms
        case redirectsScriptInterpreters
        case allowsGuardOverride
        case appearance, behavior, sharing, protection, about
        case tasks
        case fileProvider
        case log
        case version
        case daemon
        case protocolVersion
        case installRoot
        case license
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    /// Nil until the daemon answers, which is what the About section says while
    /// it waits. Never a failure: the daemon is on-demand.
    private var hello: DaemonLink.Hello?

    override func viewDidLoad() {
        super.viewDidLoad()
        switch page {
        case .main: title = String(localized: "Settings")
        case .behavior: title = String(localized: "Behavior")
        case .protection: title = String(localized: "System Protection")
        case .about: title = String(localized: "Details")
        }
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
        collectionView.contentInset.bottom = SettingsFooter.spacing
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        buildDataSource()
        apply()

        if page == .about {
            Task { [weak self] in
                let hello = await FileSession.shared.ready()
                self?.hello = hello
                self?.apply()
            }
        }
    }

    // MARK: - Content

    private func buildDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, for: row)
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
            // An instance method, not a static one: the About footer depends on
            // which backend answered, which is state.
            if let self, let section = dataSource.sectionIdentifier(for: indexPath.section) {
                content.text = self.footer(for: section)
            }
            if self?.dataSource.sectionIdentifier(for: indexPath.section) == .branding {
                content.text = "OwnGoal Studio × AI"
                content.textProperties.alignment = .center
                content.textProperties.color = .tertiaryLabel
                content.directionalLayoutMargins.top = SettingsFooter.spacing
            }
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, row in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collection, kind, indexPath in
            switch kind {
            case UICollectionView.elementKindSectionHeader:
                return collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            default:
                return collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
            }
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        switch page {
        case .main:
            snapshot.appendSections([.groups, .diagnostics, .about, .branding])
            snapshot.appendItems([.appearance, .behavior, .tasks, .sharing], toSection: .groups)
            snapshot.appendItems([.protection], toSection: .diagnostics)
            snapshot.appendItems([.version, .about, .license], toSection: .about)
        case .behavior:
            snapshot.appendSections([.browsing, .fileOperations, .systemFeatures, .scripts])
            snapshot.appendItems([.launchLocation, .recordsRecents], toSection: .browsing)
            snapshot.appendItems([.usesTrash], toSection: .fileOperations)
            snapshot.appendItems([.runsPrograms, .fileProvider], toSection: .systemFeatures)
            snapshot.appendItems([.redirectsScriptInterpreters], toSection: .scripts)
        case .protection:
            snapshot.appendSections([.guardOverride])
            snapshot.appendItems([.allowsGuardOverride], toSection: .guardOverride)
        case .about:
            snapshot.appendSections([.about])
            snapshot.appendItems([.daemon, .protocolVersion, .installRoot, .log], toSection: .about)
        }
        // Reload rather than apply: the item identifiers never change, so a
        // plain apply after the handshake lands would be an empty diff and the
        // About section would still say "Connecting…".
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    // MARK: - Rows

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        switch row {
        case .appearance:
            configureDisclosure(cell, title: String(localized: "Appearance"))
        case .behavior:
            configureDisclosure(cell, title: String(localized: "Behavior"))
        case .sharing:
            configureDisclosure(cell, title: String(localized: "File Sharing"))
        case .tasks:
            configureDisclosure(cell, title: String(localized: "Tasks"))
        case .recordsRecents:
            configureToggle(cell, title: String(localized: "Remember Recents"), keyPath: \.recordsRecents)
        case .usesTrash:
            configureToggle(cell, title: String(localized: "Use Trash"), keyPath: \.usesTrash)
        case .runsPrograms:
            configureToggle(cell, title: String(localized: "Run Programs"), keyPath: \.runsPrograms)
        case .redirectsScriptInterpreters:
            configureToggle(
                cell,
                title: String(localized: "Redirect Script Interpreters"),
                keyPath: \.redirectsScriptInterpreters
            )
        case .allowsGuardOverride:
            configureToggle(
                cell,
                title: String(localized: "Allow Overriding Protection"),
                keyPath: \.allowsGuardOverride
            )
        case .protection:
            configureDisclosure(cell, title: String(localized: "System Protection"))
        case .about:
            configureDisclosure(cell, title: String(localized: "Details"))
        case .launchLocation:
            configureLaunchLocation(cell)
        case .fileProvider:
            configureDisclosure(cell, title: String(localized: "Files App Folder"))
        case .log:
            configureDisclosure(cell, title: String(localized: "Log"))
        case .version:
            configureFact(cell, title: String(localized: "Version"), value: Self.version)
        case .daemon:
            configureFact(cell, title: String(localized: "Daemon"), value: daemonState)
        case .protocolVersion:
            // The protocol is what the two processes agreed on, so with no
            // daemon there is nothing to report — the version this build was
            // compiled with is not an agreement with anybody.
            configureFact(
                cell,
                title: String(localized: "Protocol Version"),
                value: privileged.map { String($0.protocolVersion) } ?? "—"
            )
        case .installRoot:
            // Likewise the bootstrap prefix: `InstallRoot` derives it from the
            // daemon's own `proc_pidpath`, and there is no daemon here.
            configureFact(
                cell,
                title: String(localized: "Install Root"),
                value: privileged.map { $0.installRoot.isEmpty ? "/" : $0.installRoot } ?? "—"
            )
        case .license:
            configureDisclosure(cell, title: String(localized: "Open Source Licenses"))
        }
    }

    private func configureToggle(
        _ cell: UICollectionViewListCell,
        title: String,
        keyPath: ReferenceWritableKeyPath<AppPreferences, Bool>
    ) {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = AppPreferences.shared[keyPath: keyPath]
        toggle.accessibilityLabel = title
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            AppPreferences.shared[keyPath: keyPath] = toggle.isOn
            // Browsers are behind a modal and get no callback of their own, so
            // the change has to be announced.
            NotificationCenter.default.post(name: .filaPreferencesChanged, object: nil)
        }, for: .valueChanged)
        cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
    }

    /// A pull-down button rather than a pushed list of three radio rows: three
    /// choices fit in a menu, and a whole screen to pick one of them is the
    /// kind of thing a settings screen accumulates.
    private func configureLaunchLocation(_ cell: UICollectionViewListCell) {
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Open at Launch")
        cell.contentConfiguration = content

        let button = UIButton(type: .system)
        button.setTitle(Self.name(of: AppPreferences.shared.launchLocation), for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = String(localized: "Open at Launch")
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.menu = UIMenu(children: LaunchLocation.allCases.map { location in
            UIAction(
                title: Self.name(of: location),
                state: AppPreferences.shared.launchLocation == location ? .on : .off
            ) { [weak self, weak cell] _ in
                AppPreferences.shared.launchLocation = location
                guard let cell else { return }
                self?.configureLaunchLocation(cell)
            }
        })
        button.sizeToFit()
        cell.accessories = [.customView(configuration: .init(
            customView: button,
            placement: .trailing(),
            reservedLayoutWidth: .actual
        ))]
    }

    /// The handshake, but only when it came from `filad`. Every About row that
    /// describes the daemon reads this instead of `hello`, so none of them can
    /// report a daemon fact for a build that has no daemon.
    private var privileged: DaemonLink.Hello? {
        hello?.isPrivileged == true ? hello : nil
    }

    /// Three states, not two. "Connecting…" is the honest answer while the
    /// handshake is out — `filad` is on-demand and a miss only means launchd
    /// has not spawned it yet — but it stops being honest the moment the app
    /// has settled on running without it, and the user is owed that.
    private var daemonState: String {
        guard let hello else { return String(localized: "Connecting…") }
        return hello.isPrivileged ? String(localized: "Connected") : String(localized: "Not Running")
    }

    /// Disclosure rows push; switches and menus act in place.
    private func configureDisclosure(_ cell: UICollectionViewListCell, title: String) {
        var content = UIListContentConfiguration.cell()
        content.text = title
        cell.contentConfiguration = content
        cell.accessories = [.disclosureIndicator()]
    }

    private func configureFact(_ cell: UICollectionViewListCell, title: String, value: String) {
        var content = UIListContentConfiguration.valueCell()
        content.text = title
        content.secondaryText = value
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessories = []
    }

    // MARK: - Text

    private static func header(for section: Section) -> String? {
        switch section {
        case .groups: return String(localized: "General")
        case .browsing: return String(localized: "Browsing")
        case .fileOperations: return String(localized: "File Operations")
        case .systemFeatures: return String(localized: "System Features")
        case .scripts: return String(localized: "Scripts")
        case .guardOverride: return nil
        case .branding: return nil
        case .diagnostics: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .fileOperations:
            return String(localized: "Move deleted items to the trash so they can be put back.")
        case .systemFeatures:
            return String(
                localized: "If a feature fails or stops responding, turn it off. The rest of Fila keeps working."
            )
        case .scripts:
            return String(localized: "Some scripts name an interpreter your system environment stores elsewhere. Fila finds it and runs the script. Turn this off to start scripts exactly as written.")
        case .guardOverride:
            return String(localized: "Fila blocks deleting the files iOS needs to start. Turning this on lets you delete them after a confirmation. That can stop the device from starting and require a full restore.")
        case .diagnostics:
            return nil
        case .about:
            // The only place a user is ever told they are running the
            // unprivileged build, so it says what is true and what to do about
            // it. Two different sentences because they are two very different
            // situations: a TrollStore install browses most of the device,
            // while a sideloaded one is sealed in its own container, and
            // telling the first user they can see nothing would read as the app
            // being broken.
            switch hello?.backend {
            case .none, .daemon:
                return nil
            case .local(.user):
                return String(localized: "Fila is running without root access. It can read most of the device, but it can only change files that belong to it. Install the Fila .deb on a supported device for full access.")
            case .local(.container):
                return String(localized: "Fila is running without root access. iOS limits it to its own files and the files you open in it. Install the Fila .deb on a supported device for full access.")
            }
        case .groups, .browsing, .branding:
            return nil
        }
    }

    private static func name(of location: LaunchLocation) -> String {
        switch location {
        case .root: return String(localized: "Root")
        case .home: return String(localized: "Home")
        case .lastVisited: return String(localized: "Last Visited")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    /// Only disclosure rows navigate.
    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        let row = dataSource.itemIdentifier(for: indexPath)
        if row == .tasks { return true }
        return [.appearance, .behavior, .sharing, .protection, .about, .license, .log, .fileProvider].contains(row)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        // Pushed rather than presented: settings is itself usually a sheet, and
        // a sheet over a sheet leaves either screen at half the height it needs.
        switch dataSource.itemIdentifier(for: indexPath) {
        case .appearance:
            navigationController?.pushViewController(AppearanceSettingsViewController(), animated: true)
        case .behavior:
            navigationController?.pushViewController(SettingsViewController(page: .behavior), animated: true)
        case .sharing:
            navigationController?.pushViewController(FileSharingViewController(), animated: true)
        case .tasks:
            navigationController?.pushViewController(TransfersViewController(), animated: true)
        case .license:
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        case .log:
            navigationController?.pushViewController(LogViewController(), animated: true)
        case .fileProvider:
            navigationController?.pushViewController(FileProviderSettingsViewController(), animated: true)
        case .protection:
            navigationController?.pushViewController(SettingsViewController(page: .protection), animated: true)
        case .about:
            navigationController?.pushViewController(SettingsViewController(page: .about), animated: true)
        default:
            break
        }
    }
}

extension UIViewController {
    /// Settings from a screen that has no room for it in its own hierarchy —
    /// the browser's ⋯ menu. The navigation controller and the Close button are
    /// this presentation's business, not the settings screen's.
    func presentSettings() {
        let settings = SettingsViewController()
        let navigation = UINavigationController(rootViewController: settings)
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) }
        )
        settings.navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Close")
        navigation.modalPresentationStyle = .formSheet
        if (presentedViewController as? UINavigationController)?.viewControllers.first is SidebarViewController {
            dismiss(animated: true) { [weak self] in self?.present(navigation, animated: true) }
        } else {
            present(navigation, animated: true)
        }
    }
}
