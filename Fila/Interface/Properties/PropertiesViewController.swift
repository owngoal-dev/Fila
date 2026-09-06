import AlertController
import FilaClient
import FilaMedia
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Everything `statPath` found, and the parts of it that can be changed.
///
/// This screen is where a jailbreak user finds out why something did not work.
/// Two answers account for most of it and both are here: the `uchg` flag, which
/// makes a delete fail with `EPERM` even as root and which nothing else on the
/// device will tell you about, and the guard, whose verdict is shown rather than
/// hidden so that a refusal is never a mystery.
///
/// Every edit is one `AttributeChange` with one field set. The daemon applies
/// exactly what it is given, so a screen that sent the whole struct would
/// silently re-write the owner every time somebody flipped a permission bit.
final class PropertiesViewController: UIViewController {
    private enum Section: Hashable {
        case item, size, dates, permissions, flags, link, extendedAttributes, identity, advanced

        var title: String? {
            switch self {
            case .item: return nil
            case .size: return String(localized: "Size")
            case .dates: return String(localized: "Dates")
            case .permissions: return String(localized: "Permissions")
            case .flags: return String(localized: "Flags")
            case .link: return String(localized: "Link")
            case .extendedAttributes: return String(localized: "Extended Attributes")
            case .identity: return String(localized: "Identity")
            case .advanced: return nil
            }
        }
    }

    /// What a disclosure row opens. Named rather than carried as a closure: a
    /// row is a snapshot identifier now, and a closure is neither `Hashable` nor
    /// something two runs of `rebuild` can agree about.
    private enum Action: Hashable {
        case mode, owner, group, flags, advanced
        case extendedAttribute(String)
    }

    /// Everything the cell draws, which is exactly what makes a row identical to
    /// the one it replaces — so a rebuild that changed nothing redraws nothing,
    /// and a changed value is a changed identity and is redrawn.
    private enum Row: Hashable {
        case summary
        case fact(label: String, value: String, isMonospaced: Bool)
        case disclosure(label: String, value: String, action: Action)
        case recursive(Bool)
        case note(String)
    }

    /// The section is part of the identity so that two sections stating the same
    /// fact — which no layout does today and the next one might — cannot put the
    /// same identifier in the snapshot twice.
    private struct Item: Hashable {
        let section: Section
        let row: Row
    }

    private let link: DaemonLink
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: TitledTableDataSource<Section, Item>!

    private let showsAdvanced: Bool
    private var details: FileDetails
    private var didChange: ((FileDetails) -> Void)?
    private var previewTask: Task<Void, Never>?
    private var previewImage: UIImage?
    private var previewMaximumSide: CGFloat = 192
    /// Directories only. Owner and mode changes across a tree are the one bulk
    /// edit that is genuinely needed; it is off by default because a recursive
    /// chmod of the wrong directory is not undoable.
    private var applyRecursively = false

    init(details: FileDetails, link: DaemonLink, showsAdvanced: Bool = false) {
        self.details = details
        self.link = link
        self.showsAdvanced = showsAdvanced
        super.init(nibName: nil, bundle: nil)
        title = showsAdvanced ? String(localized: "Advanced Information") : String(localized: "Properties")
        if !showsAdvanced { installActionsMenu() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        table.delegate = self
        buildDataSource()
        view.addSubview(table)
        table.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        installModalDoneButton()

        rebuild()
        if !showsAdvanced { loadPreview() }
    }

    deinit { previewTask?.cancel() }

    /// The existing media service consumes and closes the backend descriptor.
    /// A stale or cancelled preview never updates a reused/closed page.
    private func loadPreview() {
        let path = details.path
        let node = details.node
        let link = link
        previewTask = Task { [weak self] in
            let image: UIImage?
            if node.kind == .regular {
                let rendered = await ThumbnailService.shared.thumbnail(
                    path: path, modified: node.modified, byteCount: node.size, maxPixelSize: 512
                ) {
                    let descriptor = try await link.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                    var status = stat()
                    guard fstat(descriptor, &status) == 0 else {
                        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                        close(descriptor)
                        throw POSIXError(code)
                    }
                    guard status.st_mode & S_IFMT == S_IFREG else {
                        close(descriptor)
                        throw POSIXError(.EINVAL)
                    }
                    return descriptor
                }
                image = rendered.map { UIImage(cgImage: $0) }
            } else if node.isNavigable {
                let apps = await InstalledAppCatalog.load(session: .shared)
                if let identifier = AppFolderDisplay.presentation(for: path, apps: apps)?.applicationIdentifier {
                    image = await AppFolderDisplay.icon(for: identifier)
                } else { image = nil }
            } else { image = nil }
            guard !Task.isCancelled, let self, self.details.path == path, let image else { return }
            self.previewImage = image
            self.previewMaximumSide = node.kind == .regular ? 512 : 192
            // The summary identity is stable; refresh only its visible cell.
            for case let cell as PropertiesPreviewCell in self.table.visibleCells {
                cell.show(image: image, title: URL(fileURLWithPath: path).lastPathComponent,
                          kind: Self.name(of: node.kind), maximumSide: self.previewMaximumSide)
            }
            self.table.performBatchUpdates(nil)
        }
    }

    /// The file's own menu, folded behind an ellipsis: everything that writes —
    /// move, rename, compress, delete — belongs out of the way on a page that
    /// otherwise only reads. The item this page describes may cease to exist
    /// under it (renamed, moved, deleted), and then the page goes with it.
    private func installActionsMenu() {
        let path = details.path
        let node = details.node
        let actions = FileActions(presenter: self, directory: (path as NSString).deletingLastPathComponent) { [weak self] in
            self?.dismiss(animated: true)
        }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { complete in
                complete(actions.menuElements(for: path, node: node, includesProperties: false))
            },
        ]))
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more
    }

    // MARK: - Content

    private func buildDataSource() {
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        table.register(PropertiesPreviewCell.self, forCellReuseIdentifier: "Preview")
        dataSource = TitledTableDataSource(tableView: table) { [weak self] table, indexPath, item in
            let cell = table.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none

            switch item.row {
            case .summary:
                guard let self else { return cell }
                let preview = table.dequeueReusableCell(withIdentifier: "Preview", for: indexPath) as! PropertiesPreviewCell
                preview.show(image: previewImage ?? FilePresentation.largeImage(for: details.node),
                             title: URL(fileURLWithPath: details.path).lastPathComponent,
                             kind: Self.name(of: details.node.kind), maximumSide: previewMaximumSide)
                return preview

            case let .fact(label, value, isMonospaced):
                var content = UIListContentConfiguration.valueCell()
                content.text = label
                content.secondaryText = value
                content.secondaryTextProperties.numberOfLines = 0
                if isMonospaced {
                    content.secondaryTextProperties.font = FilaUI.Font.monospacedValue
                    content.secondaryTextProperties.lineBreakMode = .byCharWrapping
                }
                cell.contentConfiguration = content

            case let .disclosure(label, value, _):
                var content = UIListContentConfiguration.valueCell()
                content.text = label
                content.secondaryText = value.isEmpty ? nil : value
                content.secondaryTextProperties.numberOfLines = 0
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default

            case let .recursive(isOn):
                var content = UIListContentConfiguration.cell()
                content.text = String(localized: "Apply to Enclosed Items")
                content.textProperties.numberOfLines = 0
                cell.contentConfiguration = content
                let toggle = UISwitch()
                toggle.isOn = isOn
                toggle.accessibilityLabel = content.text
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    guard let toggle else { return }
                    self?.applyRecursively = toggle.isOn
                }, for: .valueChanged)
                cell.accessoryView = toggle

            case let .note(text):
                var content = UIListContentConfiguration.cell()
                content.text = text
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
                content.textProperties.color = .secondaryLabel
                content.textProperties.numberOfLines = 0
                cell.contentConfiguration = content
            }
            return cell
        }
        dataSource.header = { $0.title }
        dataSource.footer = { [weak self] section in section == .item ? self?.details.path : nil }
    }

    /// The whole screen, from `details`, every time anything about it changes.
    ///
    /// A row's identity is everything it draws, so an edit that changed one
    /// value replaces one row and leaves the rest of the screen — and the
    /// scroll position — where it was.
    private func rebuild() {
        let result: [(Section, [Row])]
        if showsAdvanced {
            result = [(.flags, flagRows()), (.extendedAttributes, extendedAttributeRows()), (.identity, identityRows())]
        } else {
            var summary: [(Section, [Row])] = [
                (.item, itemRows()),
                (.size, sizeRows()),
                (.permissions, permissionRows()),
                (.dates, dateRows()),
            ]
            if details.node.link != nil { summary.append((.link, linkRows())) }
            summary.append((.advanced, [.disclosure(label: String(localized: "Advanced Information"),
                value: String(localized: "Flags, extended attributes and identity"), action: .advanced)]))
            result = summary
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for (section, rows) in result {
            snapshot.appendSections([section])
            snapshot.appendItems(rows.map { Item(section: section, row: $0) }, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func itemRows() -> [Row] {
        var rows: [Row] = [
            .summary,
        ]
        if details.isDestructionProtected {
            rows.append(.note(String(localized: "The device needs this item to start up, so Fila will not delete, move or replace it. You can still edit what is inside it.")))
        }
        if details.node.isImmutable {
            rows.append(.note(String(localized: "This item is locked. Unlock it under Flags in Advanced Information to change or delete it.")))
        }
        return rows
    }

    private func sizeRows() -> [Row] {
        [
            .fact(
                label: String(localized: "Size"),
                value: Self.bytes(details.node.size),
                isMonospaced: false
            ),
            // Different from the size for anything sparse, APFS-cloned or
            // compressed, which on a phone is most of the system volume.
            .fact(
                label: String(localized: "On Disk"),
                value: Self.bytes(details.node.allocatedSize),
                isMonospaced: false
            ),
        ]
    }

    private func dateRows() -> [Row] {
        [
            .fact(label: String(localized: "Modified"), value: Self.date(details.node.modified), isMonospaced: false),
            .fact(label: String(localized: "Created"), value: Self.date(details.node.created), isMonospaced: false),
            .fact(label: String(localized: "Accessed"), value: Self.date(details.node.accessed), isMonospaced: false),
        ]
    }

    private func permissionRows() -> [Row] {
        var rows: [Row] = [
            .disclosure(
                label: String(localized: "Mode"),
                value: "\(Self.rwx(details.node.mode))  \(String(format: "%04o", details.node.mode & 0o7777))",
                action: .mode
            ),
            .disclosure(
                label: String(localized: "Owner"),
                value: Self.owner(details.node.ownerID),
                action: .owner
            ),
            .disclosure(
                label: String(localized: "Group"),
                value: Self.group(details.node.groupID),
                action: .group
            ),
        ]
        if details.hasAccessControlList {
            // Shown, not edited. An ACL is a list of entries with inheritance
            // rules, and an editor for one is its own screen; what matters here
            // is knowing that the mode is not the whole story.
            rows.append(.fact(
                label: String(localized: "Access Control List"),
                value: String(localized: "Present"),
                isMonospaced: false
            ))
        }
        if details.node.kind == .directory {
            rows.append(.recursive(applyRecursively))
        }
        return rows
    }

    private func flagRows() -> [Row] {
        let flags = details.node.systemFlags
        let enabled = FileFlagsEditorViewController.flags.filter { flags & $0.mask != 0 }.map(\.label)
        var rows: [Row] = [.disclosure(label: String(localized: "Edit Flags"),
            value: enabled.isEmpty ? String(localized: "None") : enabled.joined(separator: ", "), action: .flags)]
        if details.node.kind == .directory {
            rows.append(.recursive(applyRecursively))
        }
        // The system flags are set by the kernel and by the installer, and
        // clearing one is a decision with no undo. Shown, never toggled here.
        var system: [String] = []
        if flags & UInt32(SF_IMMUTABLE) != 0 { system.append("schg") }
        if flags & UInt32(SF_APPEND) != 0 { system.append("sappnd") }
        if flags & UInt32(SF_ARCHIVED) != 0 { system.append("arch") }
        if !system.isEmpty {
            rows.append(.fact(
                label: String(localized: "System Flags"),
                value: system.joined(separator: ", "),
                isMonospaced: true
            ))
        }
        // Only when there is something in it. On the overwhelming majority of
        // files this reads "0x00000000", and a row that says nothing on every
        // screen is what turns a list of facts into a wall.
        if flags != 0 {
            rows.append(.fact(
                label: String(localized: "Raw Value"),
                value: String(format: "0x%08x", flags),
                isMonospaced: true
            ))
        }
        return rows
    }

    private func linkRows() -> [Row] {
        guard let link = details.node.link else { return [] }
        var rows: [Row] = [
            .fact(label: String(localized: "Target"), value: link.target, isMonospaced: true),
        ]
        rows.append(.fact(
            label: String(localized: "Resolves To"),
            value: link.resolvedKind.map(Self.name(of:)) ?? String(localized: "Does not exist"),
            isMonospaced: false
        ))
        return rows
    }

    private func extendedAttributeRows() -> [Row] {
        guard !details.extendedAttributes.isEmpty else {
            // A value cell with a blank right-hand column reads as a rendering
            // bug. "None" is the answer, so it is the whole row.
            return [.note(String(localized: "This item has no extended attributes."))]
        }
        // Names are unique on a file — the kernel will not hold the same one
        // twice — so the name is identity enough for both the row and the fetch.
        return details.extendedAttributes.map { attribute in
            .disclosure(
                label: attribute.name,
                value: Self.bytes(attribute.byteCount),
                action: .extendedAttribute(attribute.name)
            )
        }
    }

    private func identityRows() -> [Row] {
        [
            .fact(label: String(localized: "Hard Links"), value: String(details.node.linkCount), isMonospaced: false),
            .fact(label: String(localized: "Inode"), value: String(details.node.inode), isMonospaced: true),
            // The path the daemon resolved, which is what every decision it made
            // was made about — `/var/mobile` reads back as `/private/var/mobile`
            // and that difference is the whole reason the guard works.
            .fact(label: String(localized: "Resolved Path"), value: details.path, isMonospaced: true),
        ]
    }

    // MARK: - Edits

    private func apply(_ change: AttributeChange) {
        var change = change
        if details.node.kind == .directory { change.isRecursive = applyRecursively }
        let path = details.path
        let link = link
        let didChange = didChange
        Task { [weak self] in
            do {
                try await link.setAttributes(change, at: path)
                let refreshed = try await link.details(of: path)
                await MainActor.run {
                    self?.details = refreshed
                    self?.rebuild()
                    didChange?(refreshed)
                }
            } catch {
                await MainActor.run {
                    self?.rebuild()
                    self?.report(error)
                }
            }
        }
    }

    private func open(_ action: Action) {
        switch action {
        case .mode: editMode()
        case .owner: editOwner()
        case .group: editGroup()
        case .flags:
            navigationController?.pushViewController(FileFlagsEditorViewController(flags: details.node.systemFlags) { [weak self] flags in
                self?.apply(AttributeChange(systemFlags: flags))
            }, animated: true)
        case .advanced:
            let advanced = PropertiesViewController(details: details, link: link, showsAdvanced: true)
            advanced.applyRecursively = applyRecursively
            advanced.didChange = { [weak self] details in
                self?.details = details
                self?.rebuild()
            }
            navigationController?.pushViewController(advanced, animated: true)
        case let .extendedAttribute(name): showAttribute(named: name)
        }
    }

    private func editMode() {
        navigationController?.pushViewController(
            ModeEditorViewController(mode: details.node.mode) { [weak self] mode in
                self?.apply(AttributeChange(mode: mode))
            },
            animated: true
        )
    }

    private func editOwner() {
        promptForIdentifier(
            title: "Owner",
            current: details.node.ownerID
        ) { [weak self] value in
            self?.apply(AttributeChange(ownerID: uid_t(value)))
        }
    }

    private func editGroup() {
        promptForIdentifier(
            title: "Group",
            current: details.node.groupID
        ) { [weak self] value in
            self?.apply(AttributeChange(groupID: gid_t(value)))
        }
    }

    /// Numeric only. A name lookup would go through `getpwnam`, which reads the
    /// passwd file as `mobile` and misses every account a bootstrap adds; a uid
    /// is unambiguous and is what the syscall takes anyway.
    private func promptForIdentifier(title: String.LocalizationValue, current: UInt32, apply: @escaping (UInt32) -> Void) {
        let alert = AlertInputViewController(
            title: title,
            message: "Enter a numeric ID. 0 is root, 501 is mobile.",
            placeholder: .noPlaceholder,
            text: String(current),
            doneButtonText: "Set"
        ) { text in
            guard let value = UInt32(text) else { return }
            apply(value)
        }
        present(alert, animated: true)
    }

    private func showAttribute(named name: String) {
        let path = details.path
        let link = link
        Task { [weak self] in
            do {
                let value = try await link.extendedAttribute(name, at: path)
                await MainActor.run {
                    self?.navigationController?.pushViewController(
                        Self.viewer(for: name, value: value),
                        animated: true
                    )
                }
            } catch {
                await MainActor.run { self?.report(error) }
            }
        }
    }

    /// A resource fork is bytes, `com.apple.metadata:*` is a binary plist, and
    /// most of the rest is a short string. Guessing right saves a trip through
    /// the hex viewer for the two common cases.
    private static func viewer(for name: String, value: Data) -> UIViewController {
        if let object = try? PropertyListSerialization.propertyList(from: value, options: [], format: nil) {
            return PropertyListEditorViewController(title: name, value: PropertyListValue(object))
        }
        return AttributeValueViewController(name: name, value: value)
    }

    private func report(_ error: Error) {
        let alert = AlertViewController(
            title: "Unable to Change Item",
            message: FailureMessage.text(for: error, whileWriting: true)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    // MARK: - Formatting

    private static func bytes(_ count: Int64) -> String {
        String(
            format: String(localized: "%@ (%lld bytes)"),
            FilePresentation.byteLabel(count),
            count
        )
    }

    /// A localized style rather than a pattern: the order of the fields, the
    /// separators and the 12-versus-24-hour clock are the reader's, not ours.
    /// Seconds are kept — on a file whose timestamps are the reason the screen
    /// is open, "which of these two was written last" is the question.
    private static func date(_ interval: Double) -> String {
        // A zero birthtime is a filesystem that never recorded one, not 1970.
        guard interval > 0 else { return String(localized: "Not recorded") }
        return Date(timeIntervalSince1970: interval)
            .formatted(date: .abbreviated, time: .standard)
    }

    static func rwx(_ mode: mode_t) -> String {
        let bits = ["r", "w", "x"]
        var result = ""
        for shift in [6, 3, 0] {
            for (index, letter) in bits.enumerated() {
                result += (mode >> mode_t(shift + 2 - index)) & 1 == 1 ? letter : "-"
            }
        }
        // setuid, setgid and sticky replace the x they ride on, the way `ls`
        // shows them — they are invisible otherwise and they change everything.
        if mode & mode_t(S_ISUID) != 0 { result = replace(result, at: 2, with: mode & 0o100 != 0 ? "s" : "S") }
        if mode & mode_t(S_ISGID) != 0 { result = replace(result, at: 5, with: mode & 0o010 != 0 ? "s" : "S") }
        if mode & mode_t(S_ISVTX) != 0 { result = replace(result, at: 8, with: mode & 0o001 != 0 ? "t" : "T") }
        return result
    }

    private static func replace(_ text: String, at offset: Int, with character: Character) -> String {
        var characters = Array(text)
        guard characters.indices.contains(offset) else { return text }
        characters[offset] = character
        return String(characters)
    }

    private static func owner(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid) else { return String(uid) }
        return "\(String(cString: entry.pointee.pw_name)) (\(uid))"
    }

    private static func group(_ gid: gid_t) -> String {
        guard let entry = getgrgid(gid) else { return String(gid) }
        return "\(String(cString: entry.pointee.gr_name)) (\(gid))"
    }

    /// Shared with the clipboard inspector, which states the same fact about the
    /// same enum and must not spell it differently.
    static func name(of kind: FileKind) -> String {
        switch kind {
        case .regular: return String(localized: "File")
        case .directory: return String(localized: "Folder")
        case .symbolicLink: return String(localized: "Symbolic Link")
        case .fifo: return String(localized: "Named Pipe")
        case .socket: return String(localized: "Socket")
        case .blockDevice: return String(localized: "Block Device")
        case .characterDevice: return String(localized: "Character Device")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension PropertiesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath)?.row else { return }
        if case let .disclosure(_, _, action) = row { open(action) }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath)?.row else { return nil }
        let value: String
        switch row {
        case let .fact(_, text, _), let .disclosure(_, text, _): value = text
        default: return nil
        }
        guard !value.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = value
            }])
        }
    }
}

/// One extended attribute's value, as text when it is text and as a dump when it
/// is not. Read-only: setting an xattr by hand is possible through
/// `AttributeChange`, but a text field is the wrong instrument for a value whose
/// meaning is a binary layout somebody else defined.
final class AttributeValueViewController: UIViewController {
    private let name: String
    private let value: Data

    init(name: String, value: Data) {
        self.name = name
        self.value = value
        super.init(nibName: nil, bundle: nil)
        title = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let textView = UITextView().then {
            $0.isEditable = false
            $0.font = FilaUI.Font.monospacedBody
            $0.adjustsFontForContentSizeCategory = true
            $0.textContainerInset = FilaUI.textContainerInset
            $0.text = String(data: value, encoding: .utf8) ?? Self.dump(value)
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private static func dump(_ data: Data) -> String {
        var lines: [String] = []
        var offset = 0
        // Capped: an xattr can be a resource fork, and a resource fork can be
        // megabytes. The full bytes are a file's worth of content and belong in
        // the hex viewer, not in a `String`.
        while offset < min(data.count, 64 * 1_024) {
            let slice = data[data.startIndex + offset ..< data.startIndex + min(offset + 16, data.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(slice.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  %@ |%@|", offset, hex, ascii))
            offset += 16
        }
        if data.count > 64 * 1_024 { lines.append("…") }
        return lines.joined(separator: "\n")
    }
}

/// User flags are edited together and applied once; system-only bits are retained.
private final class FileFlagsEditorViewController: UITableViewController {
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            apply(flags)
            navigationController?.popViewController(animated: true)
        })
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

/// A Quick Look-style presentation without copying the file to a preview URL.
private final class PropertiesPreviewCell: UITableViewCell {
    private var maximumWidth: Constraint?
    private let preview = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.tintColor = .secondaryLabel
        $0.isAccessibilityElement = false
    }
    private let nameLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .title3)
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }
    private let kindLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let labels = UIStackView(arrangedSubviews: [nameLabel, kindLabel]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(preview)
        contentView.addSubview(labels)
        preview.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.centerX.equalToSuperview()
            maximumWidth = make.width.lessThanOrEqualTo(192).constraint
            make.width.equalTo(contentView.safeAreaLayoutGuide).offset(-FilaUI.Spacing.large * 2).priority(.high)
            make.height.equalTo(preview.snp.width)
        }
        labels.snp.makeConstraints { make in
            make.top.equalTo(preview.snp.bottom).offset(FilaUI.Spacing.medium)
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().inset(FilaUI.Spacing.large)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(image: UIImage?, title: String, kind: String, maximumSide: CGFloat) {
        maximumWidth?.update(offset: maximumSide)
        preview.image = image
        nameLabel.text = title
        kindLabel.text = kind
    }
}
