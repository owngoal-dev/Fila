import Then
import UIKit

/// A read-only list of label/value pairs. Used by every viewer that has facts to
/// state and no interaction to offer.
final class KeyValueListViewController: UITableViewController {
    /// Input order identifies even repeated values in an immutable fact list.
    private struct Entry: Hashable {
        let index: Int
        let label: String
        let value: String
    }

    private let entries: [Entry]
    private var source: UITableViewDiffableDataSource<Int, Entry>!

    init(title: String, rows: [(String, String)]) {
        entries = rows.enumerated().map { Entry(index: $0.offset, label: $0.element.0, value: $0.element.1) }
        super.init(style: .insetGrouped)
        self.title = title
        let tabs = UIAction(title: String(localized: "Tabs"), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            self?.shell?.presentTabSwitcher()
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [tabs]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Only a sheet gets a Close button, and the helper is what knows the
        // difference. The same controller is pushed from the Mach-O inspector,
        // where one would sit next to a back button and do something different
        // from what it looks like.
        installModalDoneButton()

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        source = UITableViewDiffableDataSource(tableView: tableView) { table, indexPath, entry in
            let cell = table.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
            // An empty label means the value is the whole row — a dylib path,
            // say — and a value cell with a blank left column reads as a
            // rendering bug.
            cell.do {
                if entry.label.isEmpty {
                    $0.contentConfiguration = UIListContentConfiguration.cell().with {
                        $0.text = entry.value
                        $0.textProperties.font = FilaUI.Font.monospacedBody
                        $0.textProperties.numberOfLines = 0
                        $0.textProperties.lineBreakMode = .byCharWrapping
                    }
                } else {
                    $0.contentConfiguration = UIListContentConfiguration.subtitleCell().with {
                        $0.text = entry.label
                        $0.secondaryText = entry.value
                        $0.textProperties.font = .preferredFont(forTextStyle: .body)
                        $0.textProperties.numberOfLines = 0
                        $0.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: FilaUI.Font.monospacedBodySize, weight: .regular))
                        $0.secondaryTextProperties.numberOfLines = 0
                        $0.secondaryTextProperties.lineBreakMode = .byCharWrapping
                    }
                }
                $0.selectionStyle = .none
            }
            return cell
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
        snapshot.appendSections([0])
        snapshot.appendItems(entries)
        source.applySnapshotUsingReloadData(snapshot)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let entry = source.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = entry.value
            }])
        }
    }
}
