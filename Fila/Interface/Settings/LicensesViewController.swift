import FilaBackendUI
import SnapKit
import Then
import UIKit

/// Build-generated notices, including the components inside binary packages.
private struct LicenseEntry: Decodable {
    let name: String
    let license: String
    let url: String
    let text: String

    /// A notice usually names one licence; the two this app mostly ships are
    /// spelled out, everything else stands as it is — a compound expression
    /// ("MIT / BSD / 0BSD") has no shorter form, and a version beside it says
    /// nothing a person reading a licence is looking for.
    var licenseName: String {
        switch license {
        case "MIT": String(localized: "MIT License")
        case "Apache-2.0": String(localized: "Apache 2.0")
        default: license
        }
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
        // The licence is the row's explanation, not a value beside its name:
        // it belongs on the line below, at the size of the name it explains.
        content.prefersSideBySideTextAndSecondaryText = false
        content.text = entry.name
        content.secondaryText = entry.licenseName
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            LicenseTextViewController(entry: entries[indexPath.row]),
            animated: true,
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
        text.append(NSAttributedString(string: entry.licenseName + "\n\n", attributes: [
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
