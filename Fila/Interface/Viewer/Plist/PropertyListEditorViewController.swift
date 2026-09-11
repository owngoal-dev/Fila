import AlertController
import FilaBackendUI
import FilaClient
import FilaFormats
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Every level edits one document. Navigating a dictionary never creates a
/// second copy that could overwrite changes made at another level.
final class PropertyListEditorViewController: TabContentViewController {
    private final class Document {
        enum Source {
            case file(FileDetails, DescriptorFile, any LocalFileAccess)
            case readOnly(PropertyListValue)
        }

        let source: Source
        var root: PropertyListValue?
        var format: PropertyListSerialization.PropertyListFormat = .binary
        var saved: (PropertyListValue, PropertyListSerialization.PropertyListFormat)?
        var hasUnsavedChanges = false
        var isSaving = false
        weak var rootController: PropertyListEditorViewController?

        init(source: Source) {
            self.source = source
        }

        var isEditing: Bool {
            saved != nil
        }

        var canEdit: Bool {
            if case .file = source {
                return root?.supportsEditing == true
            }
            return false
        }
    }

    private struct Row {
        let path: [PropertyListStep]
        let label: String
        let value: PropertyListValue
    }

    private let document: Document
    private let path: [PropertyListStep]
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var rows: [Row] = []
    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()

    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(cancelEditing)
        )
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()

    private lazy var backItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(goBackOneLevel)
        )
        item.accessibilityLabel = String(localized: "Back")
        return item
    }()

    init(details: FileDetails, file: DescriptorFile, link: any LocalFileAccess) {
        document = Document(source: .file(details, file, link))
        path = []
        super.init(nibName: nil, bundle: nil)
        title = URL(fileURLWithPath: details.path).lastPathComponent
        document.rootController = self
        prepareBarItems()
    }

    init(title: String, value: PropertyListValue) {
        document = Document(source: .readOnly(value))
        path = []
        super.init(nibName: nil, bundle: nil)
        self.title = title
        document.rootController = self
        prepareBarItems()
    }

    private init(document: Document, row: Row) {
        self.document = document
        path = row.path
        super.init(nibName: nil, bundle: nil)
        title = row.label
        prepareBarItems()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        table.do {
            $0.delegate = self
            $0.dataSource = self
            $0.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        }
        view.addSubview(table)
        table.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        if document.root == nil {
            load()
        }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        (navigationController ?? parent ?? self).presentationController?.delegate = self
    }

    private func load() {
        switch document.source {
        case let .readOnly(value):
            document.root = value
        case let .file(_, file, _):
            do {
                let data = try file.readAll(limit: ViewerLimits.propertyListByteCount)
                var format = PropertyListSerialization.PropertyListFormat.binary
                let object = try PropertyListBudget.parse(data, format: &format)
                document.root = PropertyListValue(object)
                document.format = format
            } catch {
                table.backgroundView = StatusView(content: .message(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Unable to Read This File"),
                    detail: FailureMessage.text(for: error)
                ))
            }
        }
    }

    private func refresh() {
        rebuild()
        if document.rootController !== self {
            document.rootController?.refreshBarItems()
        }
        refreshBarItems()
    }

    private func prepareBarItems() {
        refreshBarItems()
    }

    private func refreshBarItems() {
        let editing = document.isEditing
        cancelItem.isEnabled = !document.isSaving
        table.isUserInteractionEnabled = !document.isSaving
        // A native Back history menu can skip the guarded document root.
        // Dirty nested levels therefore offer only a single-level Back.
        let guardedBack = !path.isEmpty && (document.hasUnsavedChanges || document.isSaving)
        let hidesBackButton = path.isEmpty && editing || guardedBack
        if navigationItem.hidesBackButton != hidesBackButton {
            navigationItem.hidesBackButton = hidesBackButton
            navigationItem.leftBarButtonItem = path.isEmpty && editing ? cancelItem : guardedBack ? backItem : nil
            shell?.configureSidebarButton(for: self, leadingItems: navigationItem.leftBarButtonItems ?? [])
        }
        backItem.isEnabled = !document.isSaving
        isModalInPresentation = document.hasUnsavedChanges || document.isSaving
        navigationController?.isModalInPresentation = isModalInPresentation
        navigationController?.interactivePopGestureRecognizer?.isEnabled =
            !document.isSaving && (!path.isEmpty || !document.hasUnsavedChanges)
        if let container = parent as? ViewerContainerViewController {
            trailingNavigationItems = []
            container.childMenuElements = menuElements()
            container.confirmReplacement = { [weak self] prepareToPresent, replace in
                self?.confirmLeaving(replace, prepareToPresent: prepareToPresent)
            }
            container.refreshBarItems()
        } else {
            let owner = document.rootController?.parent as? ViewerContainerViewController
            let elements = FilaMenu.groups(menuElements())
                + (owner?.fileMenuElements(presenting: self) ?? [])
            menuItem.menu = UIMenu(children: elements)
            menuItem.isEnabled = !document.isSaving
            trailingNavigationItems = [menuItem]
        }
    }

    private func menuElements() -> [UIMenuElement] {
        guard document.canEdit else { return [] }
        guard document.isEditing else {
            return [UIAction(title: String(localized: "Edit"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.startEditing()
            }]
        }
        let save = UIAction(
            title: String(localized: "Save"),
            image: UIImage(systemName: "checkmark"),
            attributes: document.hasUnsavedChanges && !document.isSaving ? [] : .disabled
        ) { [weak self] _ in self?.save() }
        let actions = [
            (String(localized: "Save as Binary"), PropertyListSerialization.PropertyListFormat.binary),
            (String(localized: "Save as XML"), PropertyListSerialization.PropertyListFormat.xml),
        ].map { title, format in
            UIAction(
                title: title,
                attributes: document.isSaving ? .disabled : [],
                state: document.format == format ? .on : .off
            ) { [weak self] _ in
                guard let self, !self.document.isSaving, document.format != format else { return }
                document.format = format
                document.hasUnsavedChanges = true
                refresh()
            }
        }
        let format = UIMenu(
            title: String(localized: "Format"),
            image: UIImage(systemName: "doc.badge.gearshape"),
            children: actions
        )
        return [save, format]
    }

    private func rebuild() {
        guard let value = document.root?.value(at: path) else { return }
        switch value {
        case let .dictionary(pairs):
            rows = pairs.map { Row(path: path + [.key($0.key)], label: $0.key, value: $0.value) }
        case let .array(items):
            rows = items.enumerated().map {
                Row(path: path + [.index($0.offset)], label: String($0.offset), value: $0.element)
            }
        default:
            rows = [Row(path: path, label: String(localized: "Value"), value: value)]
        }
        table.reloadWithAnimation()
        if rows.isEmpty {
            table.backgroundView = StatusView(content: .message(
                symbol: "list.bullet",
                title: String(localized: "No Entries"),
                detail: nil
            ))
        } else {
            table.backgroundView = nil
        }
    }

    private func startEditing() {
        guard document.canEdit, let root = document.root else { return }
        document.saved = (root, document.format)
        refresh()
    }

    @objc private func cancelEditing() {
        confirmLeaving { [weak self] in
            guard let self else { return }
            refresh()
        }
    }

    @objc private func goBackOneLevel() {
        guard !document.isSaving else { return }
        navigationController?.popViewController(animated: true)
    }

    /// Leaving offers cancellation or discarding. Saving stays in the editor,
    /// so dismissing this prompt never writes the document.
    private func confirmLeaving(_ leave: @escaping () -> Void, prepareToPresent: () -> Void = {}) {
        if let visible = navigationController?.topViewController as? PropertyListEditorViewController,
           visible !== self, visible.document === document
        {
            visible.confirmLeaving(leave, prepareToPresent: prepareToPresent)
            return
        }
        guard !document.isSaving else { return }
        guard document.hasUnsavedChanges else {
            document.saved = nil
            refresh()
            leave()
            return
        }
        prepareToPresent()
        let alert = AlertViewController(
            title: String.LocalizationValue("Unsaved Changes"),
            message: String.LocalizationValue("Leaving now discards your changes. The file on disk is unchanged.")
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Discard"), attribute: .accent) {
                context.dispose {
                    guard let self else { return }
                    if let (root, format) = self.document.saved {
                        self.document.root = root
                        self.document.format = format
                    }
                    self.document.saved = nil
                    self.document.hasUnsavedChanges = false
                    self.refresh()
                    leave()
                }
            }
        }
        present(alert, animated: true)
    }

    private func apply(_ transform: (PropertyListValue) -> PropertyListValue) {
        guard document.isEditing, !document.isSaving, let root = document.root else { return }
        let changed = transform(root)
        do {
            try PropertyListBudget.validate(changed.foundationObject)
            document.root = changed
            document.hasUnsavedChanges = true
            refresh()
        } catch {
            showError(FailureMessage.text(for: error))
        }
    }

    /// Booleans are the row's own switch, not a card: a value with two states
    /// and no confirmation to make has nothing to ask.
    private func edit(_ row: Row) {
        guard document.isEditing, !document.isSaving else { return }
        guard row.value.editableText != nil else { return }
        let alert = AlertInputViewController(
            title: row.label,
            message: row.value.typeName,
            // The computed title takes the plain-`String` overload, so the
            // placeholder and the button title are resolved here with
            // `String(localized:)` — the right overload, and visible to the
            // extractor.
            placeholder: String(localized: "Value"),
            text: row.value.editableText ?? "",
            doneButtonText: String(localized: "Done")
        ) { [weak self] text in
            guard let self else { return }
            guard let value = Self.reinterpret(text, like: row.value) else {
                showError(String(localized: "Enter a valid number for this value."))
                return
            }
            guard text != row.value.editableText else { return }
            apply { $0.replacing(row.path, with: value) }
        }
        present(alert, animated: true)
    }

    private static func reinterpret(_ text: String, like original: PropertyListValue) -> PropertyListValue? {
        switch original {
        case .string: .string(text)
        case .integer: Int64(text).map(PropertyListValue.integer)
        case .real: Double(text).flatMap { $0.isFinite ? .real($0) : nil }
        default: nil
        }
    }

    private func rename(_ row: Row) {
        guard case .key = row.path.last else { return }
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Rename Key"),
            message: String.LocalizationValue("Keys in the same dictionary must be unique."),
            placeholder: String.LocalizationValue("Key"),
            text: row.label,
            doneButtonText: String.LocalizationValue("Done")
        ) { [weak self] name in
            guard let self, !name.isEmpty, name != row.label else { return }
            let sibling = Array(row.path.dropLast()) + [.key(name)]
            guard document.root?.value(at: sibling) == nil else {
                showError(String(localized: "A key with this name already exists. Choose a different name."))
                return
            }
            apply { $0.renaming(row.path, to: name) }
        }
        present(alert, animated: true)
    }

    /// Choosing the type is a menu: five types and a way out never fit an alert
    /// card. Titles come from `typeName`, so the picker adds no new strings.
    private func addEntryMenu(for row: Row) -> UIMenu {
        let types: [(value: PropertyListValue, symbol: String)] = [
            (.string(""), "textformat"),
            (.integer(0), "number"),
            (.boolean(false), "switch.2"),
            (.array([]), "list.number"),
            (.dictionary([]), "list.bullet.indent"),
        ]
        return UIMenu(
            title: String(localized: "Add Entry"),
            image: UIImage(systemName: "plus"),
            children: types.map { value, symbol in
                UIAction(title: value.typeName, image: UIImage(systemName: symbol)) { [weak self] _ in
                    self?.addEntry(value, to: row)
                }
            }
        )
    }

    /// The type is already chosen; a dictionary still needs a key for it, and
    /// an array does not.
    private func addEntry(_ value: PropertyListValue, to row: Row) {
        guard row.value.isContainer else { return }
        guard case .dictionary = row.value else {
            apply { $0.inserting(value, key: "", into: row.path) }
            return
        }
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Add Entry"),
            message: String.LocalizationValue("Keys in the same dictionary must be unique."),
            placeholder: String.LocalizationValue("Key"),
            text: ""
        ) { [weak self] key in
            guard let self, !key.isEmpty else { return }
            guard document.root?.value(at: row.path + [.key(key)]) == nil else {
                showError(String(localized: "A key with this name already exists. Choose a different name."))
                return
            }
            apply { $0.inserting(value, key: key, into: row.path) }
        }
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        presentMessage(String(localized: "Unable to Make This Change"), message: message)
    }

    private func save() {
        guard document.canEdit, !document.isSaving, let root = document.root,
              case let .file(details, _, link) = document.source else { return }
        document.isSaving = true
        refresh()
        let format = document.format
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try PropertyListBudget.serialize(root.foundationObject, format: format)
                try await AtomicSave.write(data, to: details.path, link: link)
                document.saved = nil
                document.hasUnsavedChanges = false
                document.isSaving = false
                refresh()
            } catch {
                document.isSaving = false
                refresh()
                showError(FailureMessage.text(for: error, whileWriting: true))
            }
        }
    }
}

extension PropertyListEditorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.label
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryText = row.value.isContainer
            ? row.value.typeName + " · " + row.value.summary
            : row.value.summary
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = row.value.isContainer ? .disclosureIndicator : .none
        cell.accessoryView = nil
        if case let .boolean(flag) = row.value, document.isEditing {
            let toggle = UISwitch()
            toggle.isOn = flag
            toggle.isEnabled = !document.isSaving
            toggle.accessibilityLabel = row.label
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let toggle else { return }
                self?.apply { $0.replacing(row.path, with: .boolean(toggle.isOn)) }
            }, for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }

    func tableView(_: UITableView, titleForHeaderInSection _: Int) -> String? {
        document.root?.value(at: path)?.typeName
    }

    func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        guard document.root?.supportsEditing == false else { return nil }
        return String(localized: "This property list contains values that can be viewed but not edited.")
    }

    func tableView(_: UITableView, viewForFooterInSection _: Int) -> UIView? {
        guard document.isEditing, let value = document.root?.value(at: path), value.isContainer else { return nil }
        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Add Entry"), for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.showsMenuAsPrimaryAction = true
        button.menu = addEntryMenu(for: Row(path: path, label: title ?? "", value: value))
        return button
    }

    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
        document.isEditing && document.root?.value(at: path)?.isContainer == true ? 52 : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        if row.value.isContainer {
            pushDetail(PropertyListEditorViewController(document: document, row: row))
        } else if document.isEditing {
            edit(row)
        } else {
            pushDetail(KeyValueListViewController(title: row.label, rows: [(row.value.typeName, row.value.summary)]))
        }
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        let row = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = row.value.summary
                },
            ]
            if document.isEditing, !document.isSaving {
                if row.value.isContainer {
                    actions.append(addEntryMenu(for: row))
                }
                if case .key = row.path.last {
                    actions.append(
                        UIAction(title: String(localized: "Rename Key"), image: UIImage(systemName: "pencil")) { _ in
                            self.rename(row)
                        }
                    )
                }
                if !row.path.isEmpty {
                    actions.append(UIAction(
                        title: String(localized: "Delete"),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { _ in
                        self.apply { $0.replacing(row.path, with: nil) }
                    })
                }
            }
            let destructive = actions.filter { ($0 as? UIAction)?.attributes.contains(.destructive) == true }
            let editing = actions.filter { ($0 as? UIAction)?.attributes.contains(.destructive) != true }
            return UIMenu(children: FilaMenu.groups(editing, destructive))
        }
    }
}

extension PropertyListEditorViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        confirmLeaving { [weak self] in self?.dismiss(animated: true) }
    }
}
