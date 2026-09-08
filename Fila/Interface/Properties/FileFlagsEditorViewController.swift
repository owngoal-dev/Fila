import UIKit

/// User flags are edited together and applied once; system-only bits are retained.
final class FileFlagsEditorViewController: UITableViewController {
    static let flags: [(label: String, mask: UInt32)] = [
        (String(localized: "Locked (uchg)"), UInt32(UF_IMMUTABLE)),
        (String(localized: "Append Only (uappnd)"), UInt32(UF_APPEND)),
        (String(localized: "Hidden (hidden)"), UInt32(UF_HIDDEN)),
        (String(localized: "No Dump (nodump)"), UInt32(UF_NODUMP)),
    ]
    private var flags: UInt32
    private let apply: (UInt32) -> Void

    init(flags: UInt32, apply: @escaping (UInt32) -> Void) {
        self.flags = flags
        self.apply = apply
        super.init(style: .insetGrouped)
        title = String(localized: "Flags")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                apply(flags)
                navigationController?.popViewController(animated: true)
            }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Apply")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Self.flags.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let flag = Self.flags[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.text = flag.label
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = flags & flag.mask != 0
        toggle.accessibilityLabel = flag.label
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            flags = toggle.isOn ? flags | flag.mask : flags & ~flag.mask
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }
}
