import AlertController
import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Every level edits one document. Navigating a dictionary never creates a
/// second copy that could overwrite changes made at another level.
final class PropertyListEditorViewController: UIViewController {
    private final class Document {
        enum Source {
            case file(FileDetails, DescriptorFile, DaemonLink)
            case readOnly(PropertyListValue)
        }

        let source: Source
        var root: PropertyListValue?
        var format: PropertyListSerialization.PropertyListFormat = .binary
        var saved: (PropertyListValue, PropertyListSerialization.PropertyListFormat)?
        var hasUnsavedChanges = false
        var isSaving = false
        weak var rootController: PropertyListEditorViewController?

        init(source: Source) { self.source = source }

        var isEditing: Bool { saved != nil }
        var canEdit: Bool {
            if case .file = source { return root?.supportsEditing == true }
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
        let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(cancelEditing))
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()
    private lazy var backItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(goBackOneLevel))
        item.accessibilityLabel = String(localized: "Back")
        return item
    }()

    init(details: FileDetails, file: DescriptorFile, link: DaemonLink) {
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        if document.root == nil { load() }
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
                let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
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
        if document.rootController !== self { document.rootController?.refreshBarItems() }
        refreshBarItems()
    }

    private func prepareBarItems() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
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
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !document.isSaving && (!path.isEmpty || !document.hasUnsavedChanges)
        if let container = parent as? ViewerContainerViewController {
            navigationItem.rightBarButtonItem = nil
            container.childMenuElements = menuElements()
            container.confirmReplacement = { [weak self] replace in self?.confirmLeaving(replace) }
            container.refreshBarItems()
        } else {
            let owner = document.rootController?.parent as? ViewerContainerViewController
            let tabs = UIAction(title: String(localized: "Tabs"), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                self?.shell?.presentTabSwitcher()
            }
            let elements = menuElements() + (owner?.fileMenuElements(presenting: self) ?? []) + [tabs]
            menuItem.menu = UIMenu(children: elements)
            menuItem.isEnabled = !document.isSaving
            navigationItem.rightBarButtonItem = menuItem
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
        let actions = [(String(localized: "Save as Binary"), PropertyListSerialization.PropertyListFormat.binary),
                       (String(localized: "Save as XML"), PropertyListSerialization.PropertyListFormat.xml)].map { title, format in
            UIAction(title: title, attributes: document.isSaving ? .disabled : [], state: document.format == format ? .on : .off) { [weak self] _ in
                guard let self, !self.document.isSaving, self.document.format != format else { return }
                self.document.format = format
                self.document.hasUnsavedChanges = true
                self.refresh()
            }
        }
        let format = UIMenu(title: String(localized: "Format"), image: UIImage(systemName: "doc.badge.gearshape"), children: actions)
        return [save, format]
    }

    private func rebuild() {
        guard let value = document.root?.value(at: path) else { return }
        switch value {
        case let .dictionary(pairs):
            rows = pairs.map { Row(path: path + [.key($0.key)], label: $0.key, value: $0.value) }
        case let .array(items):
            rows = items.enumerated().map { Row(path: path + [.index($0.offset)], label: String($0.offset), value: $0.element) }
        default:
            rows = [Row(path: path, label: String(localized: "Value"), value: value)]
        }
        table.reloadData()
        if rows.isEmpty {
            table.backgroundView = StatusView(content: .message(symbol: "list.bullet", title: String(localized: "No Entries"), detail: nil))
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
            self.refresh()
        }
    }

    @objc private func goBackOneLevel() {
        guard !document.isSaving else { return }
        navigationController?.popViewController(animated: true)
    }

    /// Save and discard finish editing; a failed save retains the only current
    /// copy and never invokes the requested navigation.
    private func confirmLeaving(_ leave: @escaping () -> Void) {
        if let visible = navigationController?.topViewController as? PropertyListEditorViewController,
           visible !== self, visible.document === document {
            visible.confirmLeaving(leave)
            return
        }
        guard !document.isSaving else { return }
        guard document.hasUnsavedChanges else {
            document.saved = nil
            refresh()
            leave()
            return
        }
        let alert = AlertViewController(
            title: "Unsaved Changes",
            message: "Leaving now discards your changes. The file on disk is unchanged."
        ) { [weak self] context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: "Save", attribute: .accent) {
                context.dispose { self?.save(then: leave) }
            }
            context.addAction(title: "Discard Changes", attribute: .accent) {
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
        document.root = transform(root)
        document.hasUnsavedChanges = true
        refresh()
    }

    private func edit(_ row: Row) {
        guard document.isEditing, !document.isSaving else { return }
        if case let .boolean(flag) = row.value {
            let alert = AlertViewController(title: row.label, message: row.value.typeName) { [weak self] context in
                context.addAction(title: "Cancel") {
                    context.dispose()
                }
                context.addAction(title: "True") {
                    context.dispose {
                        guard !flag else { return }
                        self?.apply { $0.replacing(row.path, with: .boolean(true)) }
                    }
                }
                context.addAction(title: "False", attribute: .accent) {
                    context.dispose {
                        guard flag else { return }
                        self?.apply { $0.replacing(row.path, with: .boolean(false)) }
                    }
                }
            }
            present(alert, animated: true)
            return
        }
        guard row.value.editableText != nil else { return }
        let alert = AlertInputViewController(
            title: row.label,
            message: row.value.typeName,
            // The computed title takes the plain-`String` overload, so this
            // literal is not a catalogue lookup and no empty key comes of it.
            placeholder: "",
            text: row.value.editableText ?? "",
            doneButtonText: "Done"
        ) { [weak self] text in
            guard let self else { return }
            guard let value = Self.reinterpret(text, like: row.value) else {
                self.showError(String(localized: "Enter a valid number for this value."))
                return
            }
            guard text != row.value.editableText else { return }
            self.apply { $0.replacing(row.path, with: value) }
        }
        present(alert, animated: true)
    }

    private static func reinterpret(_ text: String, like original: PropertyListValue) -> PropertyListValue? {
        switch original {
        case .string: return .string(text)
        case .integer: return Int64(text).map(PropertyListValue.integer)
        case .real: return Double(text).flatMap { $0.isFinite ? .real($0) : nil }
        default: return nil
        }
    }

    private func rename(_ row: Row) {
        guard case .key = row.path.last else { return }
        let alert = AlertInputViewController(
            title: "Rename Key",
            message: "Keys in the same dictionary must be unique.",
            placeholder: .noPlaceholder,
            text: row.label,
            doneButtonText: "Done"
        ) { [weak self] name in
            guard let self, !name.isEmpty, name != row.label else { return }
            let sibling = Array(row.path.dropLast()) + [.key(name)]
            guard self.document.root?.value(at: sibling) == nil else {
                self.showError(String(localized: "A key with this name already exists. Choose a different name."))
                return
            }
            self.apply { $0.renaming(row.path, to: name) }
        }
        present(alert, animated: true)
    }

    private func addChild(to row: Row) {
        guard row.value.isContainer else { return }
        let needsKey: Bool
        if case .dictionary = row.value { needsKey = true } else { needsKey = false }
        if needsKey {
            let alert = AlertInputViewController(
                title: "Add Entry",
                message: "Enter a key for the new entry. You choose its type next.",
                placeholder: "Key",
                text: ""
            ) { [weak self] key in
                guard let self, !key.isEmpty else { return }
                guard self.document.root?.value(at: row.path + [.key(key)]) == nil else {
                    self.showError(String(localized: "A key with this name already exists. Choose a different name."))
                    return
                }
                self.presentNewEntryTypePicker(into: row.path, key: key)
            }
            present(alert, animated: true)
        } else {
            presentNewEntryTypePicker(into: row.path, key: "")
        }
    }

    private func presentNewEntryTypePicker(into path: [PropertyListStep], key: String) {
        let alert = AlertViewController(title: "Add Entry", message: "Choose the type of the new value.") { [weak self] context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: "String") {
                context.dispose { self?.apply { $0.inserting(.string(""), key: key, into: path) } }
            }
            context.addAction(title: "Number") {
                context.dispose { self?.apply { $0.inserting(.integer(0), key: key, into: path) } }
            }
            context.addAction(title: "Boolean") {
                context.dispose { self?.apply { $0.inserting(.boolean(false), key: key, into: path) } }
            }
            context.addAction(title: "Array") {
                context.dispose { self?.apply { $0.inserting(.array([]), key: key, into: path) } }
            }
            context.addAction(title: "Dictionary", attribute: .accent) {
                context.dispose { self?.apply { $0.inserting(.dictionary([]), key: key, into: path) } }
            }
        }
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = AlertViewController(title: "Unable to Save", message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    private func save(then continuation: (() -> Void)? = nil) {
        guard document.canEdit, !document.isSaving, let root = document.root, case let .file(details, _, link) = document.source else { return }
        document.isSaving = true
        refresh()
        let format = document.format
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: root.foundationObject, format: format, options: 0)
                try await AtomicSave.write(data, to: details.path, link: link)
                self.document.saved = nil
                self.document.hasUnsavedChanges = false
                self.document.isSaving = false
                self.refresh()
                continuation?()
            } catch {
                self.document.isSaving = false
                self.refresh()
                self.showError(FailureMessage.text(for: error, whileWriting: true))
            }
        }
    }
}

extension PropertyListEditorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.label
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryText = row.value.isContainer ? row.value.typeName + " · " + row.value.summary : row.value.summary
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = row.value.isContainer ? .disclosureIndicator : .none
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        document.root?.value(at: path)?.typeName
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard document.root?.supportsEditing == false else { return nil }
        return String(localized: "This property list contains values that can be viewed but not edited.")
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard document.isEditing, document.root?.value(at: path)?.isContainer == true else { return nil }
        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Add Entry"), for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.addAction(UIAction { [weak self] _ in
            guard let self, let value = self.document.root?.value(at: self.path) else { return }
            self.addChild(to: Row(path: self.path, label: self.title ?? "", value: value))
        }, for: .touchUpInside)
        return button
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        document.isEditing && document.root?.value(at: path)?.isContainer == true ? 52 : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        if row.value.isContainer {
            navigationController?.pushViewController(PropertyListEditorViewController(document: document, row: row), animated: true)
        } else if document.isEditing {
            edit(row)
        } else {
            navigationController?.pushViewController(KeyValueListViewController(title: row.label, rows: [(row.value.typeName, row.value.summary)]), animated: true)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = row.value.summary }]
            if self.document.isEditing, !self.document.isSaving {
                if row.value.isContainer {
                    actions.append(UIAction(title: String(localized: "Add Entry"), image: UIImage(systemName: "plus")) { _ in self.addChild(to: row) })
                }
                if case .key = row.path.last {
                    actions.append(UIAction(title: String(localized: "Rename Key"), image: UIImage(systemName: "pencil")) { _ in self.rename(row) })
                }
                if !row.path.isEmpty {
                    actions.append(UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                        self.apply { $0.replacing(row.path, with: nil) }
                    })
                }
            }
            return UIMenu(children: actions)
        }
    }
}

extension PropertyListEditorViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmLeaving { [weak self] in self?.dismiss(animated: true) }
    }
}
