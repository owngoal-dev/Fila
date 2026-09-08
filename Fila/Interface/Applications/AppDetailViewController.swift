import Then
import UIKit

extension InstalledApp {
    /// Where an app keeps its bytes: bundle, data container, then each group.
    var locations: [(title: String, path: String, symbol: String)] {
        var locations = [(String(localized: "App Bundle"), bundlePath, "app")]
        if let path = dataPath {
            locations.append((String(localized: "App Data"), path, "folder"))
        }
        locations += groupPaths.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value, "person.2") }
        return locations
    }
}

/// One app: its artwork and identity, what the installation database says
/// about it, and its containers. A container row pushes a browser, so Back
/// returns here and then to the list.
final class AppDetailViewController: UITableViewController {
    private let app: InstalledApp

    private enum Section: Int { case header, details }

    init(app: InstalledApp) {
        self.app = app
        super.init(style: .insetGrouped)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Open"),
            primaryAction: UIAction { _ in
                if !InstalledAppCatalog.open(app) {
                    FeedbackAlert.show(
                        String(localized: "Unable to Open App"),
                        message: String(
                            localized: "iOS could not open this app. It may be unavailable or may not have an interface."
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadWithAnimation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DirectoryPrefetch.shared.prefetch(app.locations.map(\.path))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = app.name
        navigationItem.do {
            $0.backButtonDisplayMode = .minimal
            $0.largeTitleDisplayMode = .never
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        guard AppFolderDisplay.cachedIcon(for: app.bundleIdentifier) == nil else { return }
        Task { [weak self, identifier = app.bundleIdentifier] in
            _ = await AppFolderDisplay.icon(for: identifier)
            self?.tableView.reloadWithAnimation()
        }
    }

    private var icon: UIImage? {
        AppFolderDisplay.cachedIcon(for: app.bundleIdentifier) ?? UIImage(systemName: "app")
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
        case .details: app.details.isEmpty ? nil : String(localized: "Details")
        case nil: section == 2 ? String(localized: "Locations") : nil
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
                    $0.text = location.title
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
        navigationController?.pushViewController(
            BrowserViewController(directory: app.locations[indexPath.section - 2].path),
            animated: true
        )
    }

    /// Every row's fact is copyable; the identifier and the paths are what
    /// people came to fetch.
    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        let (title, text): (String, String) = switch Section(rawValue: indexPath.section) {
        case .header: (String(localized: "Copy Bundle Identifier"), app.bundleIdentifier)
        case .details: (String(localized: "Copy"), app.details[indexPath.row].value)
        case nil: (String(localized: "Copy Path"), app.locations[indexPath.section - 2].path)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: title, image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        }
    }
}
