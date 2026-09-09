import FilaCore
import Then
import UIKit

/// One app: its artwork and identity, what the installation database says
/// about it, and its containers. A container row pushes a browser, so Back
/// returns here and then to the list.
final class ApplicationDetailViewController: UITableViewController, BackendDetailScreen {
    private let app: InstalledApp
    private let backend: ApplicationBackend
    private var bundle: Bundle { ApplicationBackend.bundle }

    private enum Section: Int { case header, details }

    init(app: InstalledApp, backend: ApplicationBackend) {
        self.app = app
        self.backend = backend
        super.init(style: .insetGrouped)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Open", bundle: bundle),
            primaryAction: UIAction { [bundle] _ in
                if !ApplicationCatalog.open(app) {
                    BackendScreens.shell?.alert(
                        title: String(localized: "Unable to Open App", bundle: bundle),
                        message: String(
                            localized: "iOS could not open this app. It may be unavailable or may not have an interface.",
                            bundle: bundle
                        )
                    )
                }
            }
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    static func title(of location: InstalledApp.Location) -> String {
        switch location.kind {
        case .bundle: String(localized: "App Bundle", bundle: ApplicationBackend.bundle)
        case .data: String(localized: "App Data", bundle: ApplicationBackend.bundle)
        case let .group(name): name
        }
    }

    static func symbol(of location: InstalledApp.Location) -> String {
        switch location.kind {
        case .bundle: "app"
        case .data: "folder"
        case .group: "person.2"
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadWithAnimation()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = app.name
        navigationItem.do {
            $0.backButtonDisplayMode = .minimal
            $0.largeTitleDisplayMode = .never
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        guard ApplicationArtworkCache.shared.cachedIcon(for: app.bundleIdentifier) == nil else { return }
        Task { [weak self, identifier = app.bundleIdentifier] in
            _ = await ApplicationArtworkCache.shared.icon(for: identifier)
            self?.tableView.reloadWithAnimation()
        }
    }

    private var icon: UIImage? {
        ApplicationArtworkCache.shared.cachedIcon(for: app.bundleIdentifier) ?? UIImage(systemName: "app")
    }

    override func numberOfSections(in _: UITableView) -> Int {
        2 + app.locations.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .header: 1
        case .details: app.details.count
        case nil: 1
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .header: nil
        case .details: app.details.isEmpty ? nil : String(localized: "Details", bundle: bundle)
        case nil: section == 2 ? String(localized: "Locations", bundle: bundle) : nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section >= 2 else { return nil }
        return app.locations[section - 2].path
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        cell.do {
            $0.selectionStyle = .none
            $0.accessoryType = .none
            switch Section(rawValue: indexPath.section) {
            case .header:
                $0.contentConfiguration = UIListContentConfiguration.subtitleCell().with {
                    $0.text = app.name
                    $0.textProperties.font = .preferredFont(forTextStyle: .title2)
                    $0.secondaryText = app.bundleIdentifier
                    $0.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
                    $0.secondaryTextProperties.color = .secondaryLabel
                    $0.textToSecondaryTextVerticalPadding = FilaUI.Spacing.compact
                    $0.image = icon
                    $0.imageProperties.maximumSize = CGSize(width: 64, height: 64)
                    $0.imageProperties.reservedLayoutSize = CGSize(width: 64, height: 64)
                    $0.imageToTextPadding = FilaUI.Spacing.large
                    $0.directionalLayoutMargins.top = FilaUI.Spacing.large
                    $0.directionalLayoutMargins.bottom = FilaUI.Spacing.large
                }
            case .details:
                let detail = app.details[indexPath.row]
                $0.contentConfiguration = UIListContentConfiguration.valueCell().with {
                    $0.text = detail.label
                    $0.secondaryText = detail.value
                    $0.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                }
            case nil:
                let location = app.locations[indexPath.section - 2]
                $0.contentConfiguration = UIListContentConfiguration.subtitleCell().with {
                    $0.text = Self.title(of: location)
                    $0.image = icon
                    $0.imageProperties.maximumSize = CGSize(width: FilaUI.IconSize.file, height: FilaUI.IconSize.file)
                    $0.imageProperties.reservedLayoutSize = CGSize(
                        width: FilaUI.IconSize.file,
                        height: FilaUI.IconSize.file
                    )
                    $0.textProperties.numberOfLines = 0
                }
                $0.selectionStyle = .default
                $0.accessoryType = .disclosureIndicator
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section >= 2 else { return }
        let path = app.locations[indexPath.section - 2].path
        guard let location = backend.local.servicePath(forAbsolute: path),
              let browser = BackendScreens.shell?.browser(
                  for: BackendLocation(backend: backend.local.id, item: location.description)
              ) else { return }
        navigationController?.pushViewController(browser, animated: true)
    }

    /// Every row's fact is copyable; the identifier and the paths are what
    /// people came to fetch.
    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        let (title, text): (String, String) = switch Section(rawValue: indexPath.section) {
        case .header: (String(localized: "Copy Bundle Identifier", bundle: bundle), app.bundleIdentifier)
        case .details: (String(localized: "Copy", bundle: bundle), app.details[indexPath.row].value)
        case nil: (String(localized: "Copy Path", bundle: bundle), app.locations[indexPath.section - 2].path)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: title, image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        }
    }
}
