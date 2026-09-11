import FilaBackendKit
import AlertController
import FilaBackendUI
import FilaClient
import FilaFormats
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
final class PropertiesViewController: TabContentViewController {
    private enum Section: Hashable {
        case item, size, dates, permissions, flags, link, extendedAttributes, identity, advanced, media, checksums

        var title: String? {
            switch self {
            case .item: nil
            case .size: String(localized: "Size")
            case .dates: String(localized: "Dates")
            case .permissions: String(localized: "Permissions")
            case .flags: String(localized: "Flags")
            case .link: String(localized: "Link")
            case .extendedAttributes: String(localized: "Extended Attributes")
            case .identity: String(localized: "Identity")
            case .advanced: nil
            case .media: String(localized: "Media")
            case .checksums: String(localized: "Checksums")
            }
        }
    }

    /// What a disclosure row opens. Named rather than carried as a closure: a
    /// row is a snapshot identifier now, and a closure is neither `Hashable` nor
    /// something two runs of `rebuild` can agree about.
    private enum Action: Hashable {
        case mode, owner, group, flags, advanced, calculateChecksums, cancelChecksums
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

    private let link: any LocalFileAccess
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: TitledTableDataSource<Section, Item>!

    private let showsAdvanced: Bool
    private var details: FileDetails
    private var didChange: ((FileDetails) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var checksumTask: Task<FileChecksums, Error>?
    private var checksums: FileChecksums?
    private var mediaTask: Task<Void, Never>?
    private var mediaInformation: FileMediaInformation?
    private var previewImage: UIImage?
    private var previewMaximumSide: CGFloat = 192
    /// Directories only. Owner and mode changes across a tree are the one bulk
    /// edit that is genuinely needed; it is off by default because a recursive
    /// chmod of the wrong directory is not undoable.
    private var applyRecursively = false

    init(details: FileDetails, link: any LocalFileAccess, showsAdvanced: Bool = false) {
        self.details = details
        self.link = link
        self.showsAdvanced = showsAdvanced
        super.init(nibName: nil, bundle: nil)
        title = showsAdvanced ? String(localized: "Advanced Information") : String(localized: "Properties")
        if !showsAdvanced {
            installActionsMenu()
            // The item, then this screen — drawn only in a tab, where a crumb
            // on a folder goes back to its browser.
            let screen = PathBarView.Crumb(title: title ?? "", icon: UIImage(systemName: "info.circle"))
            decorationSource = details.node.kind == .directory
                ? LocalPathDecoration(directory: details.path, screen: screen)
                : LocalPathDecoration(path: details.path, icon: FilePresentation.image(for: details.node), screen: screen)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
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

        installModalDoneButton()

        rebuild()
        if !showsAdvanced {
            loadPreview()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTask?.cancel()
        let path = details.path
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await link.details(of: path)
                guard !Task.isCancelled else { return }
                let previous = details.node
                let current = updated.node
                if previous.inode != current.inode || previous.size != current.size
                    || previous.modified != current.modified || previous.kind != current.kind
                {
                    checksumTask?.cancel()
                    checksumTask = nil
                    checksums = nil
                    mediaInformation = nil
                    previewImage = nil
                }
                details = updated
                rebuild()
                if !showsAdvanced {
                    loadPreview(); loadMediaInformation()
                }
            } catch {
                guard !Task.isCancelled else { return }
                FeedbackAlert.show(
                    String(localized: "Unable to Read Item"),
                    message: FailureMessage.text(for: error)
                )
            }
        }
    }

    deinit { previewTask?.cancel(); refreshTask?.cancel(); checksumTask?.cancel(); mediaTask?.cancel() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            checksumTask?.cancel()
            mediaTask?.cancel()
            previewTask?.cancel()
        }
    }

    /// The file's own picture, a navigable bundle's app artwork, or the OS's
    /// picture of its type at the page's size — the row's is too small here.
    /// A stale or cancelled preview never updates a reused/closed page.
    private func loadPreview() {
        previewTask?.cancel()
        let path = details.path
        let node = details.node
        previewTask = Task { [weak self] in
            var image: UIImage?
            var maximumSide = FilePresentation.largeSide
            // `link` is always `FileSession.shared.link`: every caller passes
            // `session.link`, and there is one session.
            switch await FilePresentation.picture(for: path, node: node, session: .shared, large: true) {
            case let .icon(icon)?:
                image = icon
            case let .thumbnail(thumbnail)?:
                // A white page on the white cell has no edge of its own.
                image = FilePresentation.edged(thumbnail)
                maximumSide = 512
            case nil:
                if node.isNavigable {
                    let decoration = await SystemCapabilities.applications?.decorationLookup()
                    if let identifier = decoration?(path)?.applicationIdentifier,
                       let artwork = SystemCapabilities.applicationArtwork
                    {
                        image = await artwork.icon(for: identifier)
                    }
                }
                if image == nil, case let .device(subject) = FilePresentation.icon(for: node) {
                    image = await DeviceIcons.largeImage(for: subject)
                }
            }
            guard !Task.isCancelled, let self, details.path == path, let image else { return }
            previewImage = image
            previewMaximumSide = maximumSide
            // The summary identity is stable; refresh only its visible cell.
            for case let cell as PropertiesPreviewCell in self.table.visibleCells {
                cell.show(
                    image: image,
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    kind: Self.name(of: node.kind),
                    maximumSide: previewMaximumSide
                )
            }
            table.performBatchUpdates(nil)
        }
    }

    /// The file's own menu, folded behind an ellipsis: everything that writes —
    /// move, rename, compress, delete — belongs out of the way on a page that
    /// otherwise only reads. The item this page describes may cease to exist
    /// under it (renamed, moved, deleted), and then the page goes with it.
    private func installActionsMenu() {
        let path = details.path
        let node = details.node
        let actions = FileActions(
            presenter: self,
            directory: (path as NSString).deletingLastPathComponent
        ) { [weak self] in
            self?.dismiss(animated: true)
        }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { complete in
                complete(actions.menuElements(for: path, node: node, includesProperties: false))
            },
            settingsMenuElement,
        ]))
        more.accessibilityLabel = String(localized: "More")
        trailingNavigationItems = [more]
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
                let preview = table.dequeueReusableCell(
                    withIdentifier: "Preview",
                    for: indexPath
                ) as! PropertiesPreviewCell
                preview.show(
                    image: previewImage ?? FilePresentation.image(for: details.node),
                    title: URL(fileURLWithPath: details.path).lastPathComponent,
                    kind: Self.name(of: details.node.kind),
                    maximumSide: previewMaximumSide
                )
                return preview

            case let .fact(label, value, isMonospaced):
                var content = UIListContentConfiguration.valueCell()
                content.text = label
                content.secondaryText = value
                content.secondaryTextProperties.numberOfLines = 1
                content.prefersSideBySideTextAndSecondaryText = true
                if isMonospaced {
                    content.secondaryTextProperties.font = FilaUI.Font.monospacedValue
                    content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                }
                cell.contentConfiguration = content
                if item.section == .checksums {
                    cell.accessoryType = .disclosureIndicator
                    cell.selectionStyle = .default
                }

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
        dataSource.footer = { [weak self] section in
            if section == .item {
                return self?.details.path
            }
            if section == .checksums {
                return self?.checksums == nil
                    ? String(localized: "Calculate checksums to compare files.")
                    : String(localized: "Tap a checksum to view it in full. Touch and hold to copy.")
            }
            return nil
        }
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
            if details.node.kind == .regular {
                if let mediaInformation {
                    var rows: [Row] = []
                    if let width = mediaInformation.width, let height = mediaInformation.height, width > 0, height > 0 {
                        rows.append(.fact(
                            label: String(localized: "Resolution"),
                            value: "\(width.formatted(.number.precision(.fractionLength(0)))) × \(height.formatted(.number.precision(.fractionLength(0))))",
                            isMonospaced: false
                        ))
                    }
                    if let duration = mediaInformation.duration {
                        let formatter = DateComponentsFormatter()
                        formatter.allowedUnits = [.hour, .minute, .second]
                        formatter.unitsStyle = .positional
                        formatter.zeroFormattingBehavior = .pad
                        rows.append(.fact(
                            label: String(localized: "Duration"),
                            value: formatter.string(from: duration) ?? "",
                            isMonospaced: false
                        ))
                    }
                    if let rate = mediaInformation.frameRate {
                        rows.append(.fact(
                            label: String(localized: "Frame Rate"),
                            value: String(localized: "\(rate.formatted(.number.precision(.fractionLength(0 ... 3)))) fps"),
                            isMonospaced: false
                        ))
                    }
                    if !rows.isEmpty {
                        summary.insert((.media, rows), at: 2)
                    }
                }
                if let checksums {
                    summary.append((.checksums, [
                        .fact(label: "MD5", value: checksums.md5, isMonospaced: true),
                        .fact(label: "SHA-1", value: checksums.sha1, isMonospaced: true),
                        .fact(label: "SHA-256", value: checksums.sha256, isMonospaced: true),
                    ]))
                } else {
                    summary.append((.checksums, [.disclosure(
                        label: checksumTask == nil
                            ? String(localized: "Calculate Checksums")
                            : String(localized: "Cancel Calculation"),
                        value: checksumTask == nil ? "MD5, SHA-1, SHA-256" : String(localized: "Calculating…"),
                        action: checksumTask == nil ? .calculateChecksums : .cancelChecksums
                    )]))
                }
            }
            if details.node.link != nil {
                summary.append((.link, linkRows()))
            }
            summary.append((.advanced, [.disclosure(
                label: String(localized: "Advanced Information"),
                value: String(localized: "Flags, extended attributes and identity"),
                action: .advanced
            )]))
            result = summary
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for (section, rows) in result {
            snapshot.appendSections([section])
            snapshot.appendItems(rows.map { Item(section: section, row: $0) }, toSection: section)
        }
        if snapshot.sectionIdentifiers.contains(.checksums),
           dataSource.snapshot().sectionIdentifiers.contains(.checksums) {
            snapshot.reloadSections([.checksums])
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func itemRows() -> [Row] {
        var rows: [Row] = [
            .summary,
        ]
        if details.isDestructionProtected {
            rows.append(.note(String(localized: "The device needs this item to start up, so Fila will not delete, move or replace it. You can still edit what is inside it.")))
        }
        if details.node.isImmutable {
            rows.append(.note(String(
                localized: "This item is locked. Unlock it under Flags in Advanced Information to change or delete it."
            )))
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
        var rows: [Row] = [.disclosure(
            label: String(localized: "Edit Flags"),
            value: enabled.isEmpty ? String(localized: "None") : enabled.joined(separator: ", "),
            action: .flags
        )]
        if details.node.kind == .directory {
            rows.append(.recursive(applyRecursively))
        }
        // The system flags are set by the kernel and by the installer, and
        // clearing one is a decision with no undo. Shown, never toggled here.
        var system: [String] = []
        if flags & UInt32(SF_IMMUTABLE) != 0 {
            system.append("schg")
        }
        if flags & UInt32(SF_APPEND) != 0 {
            system.append("sappnd")
        }
        if flags & UInt32(SF_ARCHIVED) != 0 {
            system.append("arch")
        }
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
        if details.node.kind == .directory {
            change.isRecursive = applyRecursively
        }
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
        case .calculateChecksums: calculateChecksums()
        case .cancelChecksums: checksumTask?.cancel()
        case .mode: editMode()
        case .owner: editOwner()
        case .group: editGroup()
        case .flags:
            pushDetail(FileFlagsEditorViewController(flags: details.node.systemFlags) { [weak self] flags in
                self?.apply(AttributeChange(systemFlags: flags))
            })
        case .advanced:
            let advanced = PropertiesViewController(details: details, link: link, showsAdvanced: true)
            advanced.applyRecursively = applyRecursively
            advanced.didChange = { [weak self] details in
                self?.details = details
                self?.rebuild()
            }
            pushDetail(advanced)
        case let .extendedAttribute(name): showAttribute(named: name)
        }
    }

    private func calculateChecksums() {
        guard checksumTask == nil else { return }
        let path = details.path
        let link = link
        let task = Task.detached(priority: .utility) {
            let descriptor = try await link.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            defer { close(descriptor) }
            return try FileChecksums.read(descriptor: descriptor)
        }
        checksumTask = task
        rebuild()
        Task { [weak self] in
            let result = await task.result
            guard let self, checksumTask == task else { return }
            checksumTask = nil
            if !task.isCancelled {
                switch result {
                case let .success(value): checksums = value
                case let .failure(error):
                    let message = (error as? POSIXError)?.code == .EBUSY
                        ? String(localized: "The file changed during calculation. Try again.")
                        : FailureMessage.text(for: error)
                    FeedbackAlert.show(String(localized: "Unable to Calculate Checksums"), message: message)
                }
            }
            rebuild()
        }
    }

    private func loadMediaInformation() {
        mediaTask?.cancel()
        guard details.node.kind == .regular else { return }
        let format = FilePresentation.format(of: details.node)
        guard format == .image || format == .audio || format == .video else { return }
        let path = details.path
        let name = details.node.name
        let link = link
        mediaTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                let descriptor = try await link.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                defer { close(descriptor) }
                return try await FileMediaInformation.read(descriptor: descriptor, name: name)
            }
            let result = try? await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            mediaInformation = result
            rebuild()
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
            title: String.LocalizationValue("Owner"),
            current: details.node.ownerID
        ) { [weak self] value in
            self?.apply(AttributeChange(ownerID: uid_t(value)))
        }
    }

    private func editGroup() {
        promptForIdentifier(
            title: String.LocalizationValue("Group"),
            current: details.node.groupID
        ) { [weak self] value in
            self?.apply(AttributeChange(groupID: gid_t(value)))
        }
    }

    /// Numeric only. A name lookup would go through `getpwnam`, which reads the
    /// passwd file as `mobile` and misses every account a bootstrap adds; a uid
    /// is unambiguous and is what the syscall takes anyway.
    private func promptForIdentifier(
        title: String.LocalizationValue,
        current: UInt32,
        apply: @escaping (UInt32) -> Void
    ) {
        let alert = AlertInputViewController(
            title: title,
            message: String.LocalizationValue("Enter a numeric ID. 0 is root, 501 is mobile."),
            placeholder: String.LocalizationValue("Numeric ID"),
            text: String(current),
            doneButtonText: String.LocalizationValue("Set")
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
        var format = PropertyListSerialization.PropertyListFormat.binary
        if let object = try? PropertyListBudget.parse(value, format: &format) {
            return PropertyListEditorViewController(title: name, value: PropertyListValue(object))
        }
        return AttributeValueViewController(name: name, value: value)
    }

    private func report(_ error: Error) {
        presentMessage(
            String(localized: "Unable to Change Item"),
            message: FailureMessage.text(for: error, whileWriting: true)
        )
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
        if mode & mode_t(S_ISUID) != 0 {
            result = replace(result, at: 2, with: mode & 0o100 != 0 ? "s" : "S")
        }
        if mode & mode_t(S_ISGID) != 0 {
            result = replace(result, at: 5, with: mode & 0o010 != 0 ? "s" : "S")
        }
        if mode & mode_t(S_ISVTX) != 0 {
            result = replace(result, at: 8, with: mode & 0o001 != 0 ? "t" : "T")
        }
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
        case .regular: String(localized: "File")
        case .directory: String(localized: "Folder")
        case .symbolicLink: String(localized: "Symbolic Link")
        case .fifo: String(localized: "Named Pipe")
        case .socket: String(localized: "Socket")
        case .blockDevice: String(localized: "Block Device")
        case .characterDevice: String(localized: "Character Device")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension PropertiesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if case let .disclosure(_, _, action) = item.row {
            open(action)
        } else if item.section == .checksums, case let .fact(label, value, _) = item.row {
            let alert = AlertViewController(title: label, message: value) { context in
                context.addAction(title: String.LocalizationValue("Close")) { context.dispose() }
                context.addAction(title: String.LocalizationValue("Copy"), attribute: .accent) {
                    context.dispose { UIPasteboard.general.string = value }
                }
            }
            present(alert, animated: true)
        }
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath)?.row else { return nil }
        let value: String
        switch row {
        case let .fact(_, text, _), let .disclosure(_, text, _): value = text
        default: return nil
        }
        guard !value.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                },
            ])
        }
    }
}
