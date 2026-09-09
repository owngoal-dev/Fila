import FilaBackendUI
import SnapKit
import Then
import UIKit

/// Build-generated notices, including the components inside binary packages.
private struct LicenseEntry: Decodable {
    let id: String
    let name: String
    let version: String?
    let license: String
    let url: String
    let text: String

    var summary: String {
        [license, version].compactMap(\.self).joined(separator: " · ")
    }
}

/// Adapted from iGhostVT's LicensesView; UIKit owns Fila's navigation stack.
final class LicensesViewController: UITableViewController {
    private var entries: [LicenseEntry] = []

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadWithAnimation()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Open Source Licenses")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.contentInset.bottom = FilaUI.Spacing.settingsTail
        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        {
            entries = decoded
        }
        if entries.isEmpty {
            tableView.backgroundView = UILabel().then {
                $0.text = String(localized: "No license information is available.")
                $0.font = .preferredFont(forTextStyle: .body)
                $0.textColor = .secondaryLabel
                $0.numberOfLines = 0
                $0.textAlignment = .center
                $0.adjustsFontForContentSizeCategory = true
            }
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "license")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "license")
        let entry = entries[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = entry.name
        content.textProperties.numberOfLines = 1
        content.secondaryText = entry.summary
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            LicenseTextViewController(entry: entries[indexPath.row]),
            animated: true
        )
    }
}

/// Selectable, wrapping full text; links use UITextView's native interaction.
private final class LicenseTextViewController: UIViewController {
    private let entry: LicenseEntry

    init(entry: LicenseEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.name
        view.backgroundColor = .systemGroupedBackground
        let text = NSMutableAttributedString(string: entry.name + "\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .title2), .foregroundColor: UIColor.label,
        ])
        text.append(NSAttributedString(string: entry.summary + "\n\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
        ]))
        if let url = URL(string: entry.url), ["https", "http"].contains(url.scheme) {
            text.append(NSAttributedString(string: entry.url + "\n\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote), .link: url,
            ]))
        }
        text.append(NSAttributedString(string: entry.text, attributes: [
            .font: FilaUI.Font.monospacedFootnote, .foregroundColor: UIColor.label,
        ]))
        let textView = UITextView().then {
            $0.isEditable = false
            $0.isSelectable = true
            $0.backgroundColor = .clear
            $0.adjustsFontForContentSizeCategory = true
            $0.textContainerInset = FilaUI.textContainerInset
            $0.contentInset.bottom = FilaUI.Spacing.settingsTail
            $0.attributedText = text
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
    }
}
