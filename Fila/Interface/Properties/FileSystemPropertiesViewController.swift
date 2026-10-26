import FilaBackendUI
import FilaProtocol
import SnapKit
import UIKit

/// The volume a folder sits on: where it is mounted, what it is formatted as,
/// who owns it and how much of it is left. One row per fact.
///
/// Reached from the end of the list — the free space and the read-only mark are
/// the volume talking, so touching either of them opens this.
final class FileSystemPropertiesViewController: UITableViewController {
    private enum Row: CaseIterable {
        case path
        case mountedOn
        case format
        case permissions
        case owner
        case size
        case used
        case available

        /// The rows whose value is a path: it goes on its own line, because a
        /// path beside a label is a path with its middle cut out.
        var isWrapping: Bool {
            switch self {
            case .path, .mountedOn: true
            case .format, .permissions, .owner, .size, .used, .available: false
            }
        }
    }

    private let volume: VolumeInfo
    /// Where the mount point goes when its row is tapped: the browser under
    /// this sheet.
    private let openMountPoint: ((String) -> Void)?

    init(volume: VolumeInfo, openMountPoint: ((String) -> Void)? = nil) {
        self.volume = volume
        self.openMountPoint = openMountPoint
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Filesystem")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.contentInset.bottom = FilaUI.Spacing.settingsTail
        installModalDoneButton()
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "fact")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "fact")
        let row = Row.allCases[indexPath.row]
        // The mount point is somewhere to go: it is the one row that leads out
        // of this sheet.
        let leads = row == .mountedOn && openMountPoint != nil
        cell.selectionStyle = leads ? .default : .none
        cell.accessoryType = leads ? .disclosureIndicator : .none
        var content = UIListContentConfiguration.valueCell()
        content.text = label(for: row)
        content.secondaryText = value(for: row)
        content.prefersSideBySideTextAndSecondaryText = !row.isWrapping
        content.secondaryTextProperties.numberOfLines = row.isWrapping ? 0 : 1
        if row.isWrapping {
            content.secondaryTextProperties.font = FilaUI.Font.monospacedValue
            content.secondaryTextProperties.lineBreakMode = .byCharWrapping
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Row.allCases[indexPath.row] == .mountedOn, let openMountPoint else { return }
        let path = volume.mountPoint
        dismiss(animated: true) { openMountPoint(path) }
    }

    private func label(for row: Row) -> String {
        switch row {
        case .path: String(localized: "File System Path")
        case .mountedOn: String(localized: "Mounted On")
        case .format: String(localized: "Format")
        case .permissions: String(localized: "Permissions")
        case .owner: String(localized: "Owner UID")
        case .size: String(localized: "Size")
        case .used: String(localized: "Used")
        case .available: String(localized: "Available")
        }
    }

    private func value(for row: Row) -> String {
        switch row {
        case .path: volume.deviceName
        case .mountedOn: volume.mountPoint
        case .format: volume.filesystemType.uppercased()
        case .permissions: volume.isReadOnly ? String(localized: "Read Only") : String(localized: "Read-Write")
        case .owner: String(volume.ownerUID)
        case .size: FilePresentation.byteLabel(volume.totalByteCount)
        case .used: FilePresentation.byteLabel(volume.totalByteCount - volume.availableByteCount)
        case .available: FilePresentation.byteLabel(volume.availableByteCount)
        }
    }
}
