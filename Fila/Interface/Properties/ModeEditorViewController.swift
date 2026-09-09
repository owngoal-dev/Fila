import AlertController
import FilaBackendUI
import SnapKit
import Then
import UIKit

/// The permission bits, as the rwx grid and as the octal, both live.
///
/// Both spellings because both are what people already have in their heads:
/// somebody fixing a launchd job knows it wants `0644` and somebody fixing a
/// binary knows it needs to be executable, and neither should have to translate.
/// Editing either updates the other, and nothing is sent until Apply — a chmod
/// that fired on every toggle would walk the file through six wrong modes on the
/// way to the right one, and on a directory with "apply to enclosed items" on,
/// each of those is a tree walk.
final class ModeEditorViewController: UIViewController {
    /// Also the row's identity: every mask on this screen is a different bit, so
    /// no two rows can hash the same. What the row *draws* — the switch — is not
    /// in here, because it is read from `mode` when the cell is made.
    private struct Bit: Hashable {
        let label: String
        let mask: mode_t
    }

    private enum Section: Hashable {
        case octal
        case permissions, special
    }

    private enum Item: Hashable {
        case octal
        case group(Int)
        case bit(Bit)
    }

    /// setuid, setgid and sticky are here because they are the ones that matter
    /// and the ones the rwx string hides.
    private static let bits: [(section: String, entries: [Bit])] = [
        (String(localized: "Owner"), [
            Bit(label: String(localized: "Read"), mask: 0o400),
            Bit(label: String(localized: "Write"), mask: 0o200),
            Bit(label: String(localized: "Execute"), mask: 0o100),
        ]),
        (String(localized: "Group"), [
            Bit(label: String(localized: "Read"), mask: 0o040),
            Bit(label: String(localized: "Write"), mask: 0o020),
            Bit(label: String(localized: "Execute"), mask: 0o010),
        ]),
        (String(localized: "Everyone"), [
            Bit(label: String(localized: "Read"), mask: 0o004),
            Bit(label: String(localized: "Write"), mask: 0o002),
            Bit(label: String(localized: "Execute"), mask: 0o001),
        ]),
        (String(localized: "Special"), [
            Bit(label: String(localized: "Set User ID"), mask: 0o4000),
            Bit(label: String(localized: "Set Group ID"), mask: 0o2000),
            Bit(label: String(localized: "Sticky"), mask: 0o1000),
        ]),
    ]

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: TitledTableDataSource<Section, Item>!
    private let apply: (mode_t) -> Void
    /// Permission bits only. The file-type bits in `st_mode` are the kernel's
    /// and `chmod` does not take them.
    private var mode: mode_t

    init(mode: mode_t, apply: @escaping (mode_t) -> Void) {
        self.mode = mode & 0o7777
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Permissions")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(commit)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Apply")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh(dataSource.snapshot().itemIdentifiers)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        table.delegate = self
        buildDataSource()
        view.addSubview(table)
        table.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // MARK: - List

    private func buildDataSource() {
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        table.register(PermissionGroupCell.self, forCellReuseIdentifier: "Group")
        dataSource = TitledTableDataSource(tableView: table) { [weak self] table, indexPath, item in
            if case let .group(index) = item, let self {
                let cell = table.dequeueReusableCell(withIdentifier: "Group", for: indexPath) as! PermissionGroupCell
                let group = Self.bits[index]
                cell.configure(
                    title: group.section,
                    permissions: group.entries.map { ($0.label, self.mode & $0.mask != 0) }
                ) { [weak self] bitIndex in
                    guard let self else { return }
                    mode ^= group.entries[bitIndex].mask
                    refresh([.octal, .group(index)])
                }
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
            guard let self else { return cell }
            cell.accessoryView = nil
            cell.accessoryType = .none

            guard case let .bit(bit) = item else {
                var content = UIListContentConfiguration.valueCell()
                content.text = String(format: "%04o", mode)
                content.textProperties.font = UIFontMetrics(forTextStyle: .title2)
                    .scaledFont(for: .monospacedSystemFont(ofSize: 24, weight: .medium))
                content.secondaryText = PropertiesViewController.rwx(mode)
                content.secondaryTextProperties.font = FilaUI.Font.monospacedValue
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            }

            var content = UIListContentConfiguration.cell()
            content.text = bit.label
            cell.contentConfiguration = content
            cell.selectionStyle = .none

            let toggle = UISwitch()
            toggle.isOn = mode & bit.mask != 0
            toggle.accessibilityLabel = bit.label
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                mode = toggle.isOn ? mode | bit.mask : mode & ~bit.mask
                // Only the summary row moves; reconfiguring the whole table
                // would drop the switch the finger is still on.
                refresh([.octal])
            }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        }
        dataSource.header = { section in
            switch section {
            case .octal: String(localized: "Octal Mode")
            case .permissions: String(localized: "Permissions")
            case .special: String(localized: "Special")
            }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.octal, .permissions, .special])
        snapshot.appendItems([.octal], toSection: .octal)
        snapshot.appendItems((0 ..< 3).map(Item.group), toSection: .permissions)
        snapshot.appendItems(Self.bits[3].entries.map(Item.bit), toSection: .special)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    /// Redraws rows whose identity did not change but whose content did — the
    /// diffable answer to `reloadRows`, and the reason `mode` is not part of any
    /// identifier.
    private func refresh(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func commit() {
        apply(mode)
        navigationController?.popViewController(animated: true)
    }

    private func promptForOctal() {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Octal Mode"),
            message: String.LocalizationValue("Enter three or four octal digits (0–7)."),
            placeholder: .noPlaceholder,
            text: String(format: "%04o", mode),
            doneButtonText: String.LocalizationValue("Set")
        ) { [weak self] text in
            guard let self, let value = UInt32(text, radix: 8),
                  (3 ... 4).contains(text.count), value <= 0o7777 else { return }
            mode = mode_t(value)
            // Every switch as well as the summary: an octal typed in here can
            // change any of the twelve bits.
            refresh(dataSource.snapshot().itemIdentifiers)
        }
        present(alert, animated: true)
    }
}

extension ModeEditorViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .octal {
            promptForOctal()
        }
    }
}

/// Native buttons keep each permission target at least 44 pt. Larger text
/// stacks the choices so a narrow iPhone never has to shrink their labels.
private final class PermissionGroupCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let choices = UIStackView()
    private let buttons = (0 ..< 3).map { _ in UIButton(type: .system) }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
        }
        choices.do {
            $0.distribution = .fillEqually
            $0.spacing = FilaUI.Spacing.small
        }
        for button in buttons {
            choices.addArrangedSubview(button)
            button.snp.makeConstraints { make in
                make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
            }
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, choices]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.small
        }
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        choices.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
    }

    func configure(title: String, permissions: [(String, Bool)], change: @escaping (Int) -> Void) {
        titleLabel.text = title
        choices.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        for (index, permission) in permissions.enumerated() {
            let button = buttons[index]
            var configuration = UIButton.Configuration.plain()
            configuration.title = permission.0
            configuration.image = UIImage(systemName: permission.1 ? "checkmark.circle.fill" : "circle")
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: FilaUI.Spacing.small,
                leading: 0,
                bottom: FilaUI.Spacing.small,
                trailing: 0
            )
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
                return attributes
            }
            button.configuration = configuration
            button.accessibilityLabel = "\(title), \(permission.0)"
            button.accessibilityTraits = permission.1 ? [.button, .selected] : .button
            button.removeAction(identifiedBy: UIAction.Identifier("permission"), for: .touchUpInside)
            button.addAction(
                UIAction(identifier: UIAction.Identifier("permission")) { _ in change(index) },
                for: .touchUpInside
            )
        }
    }
}
