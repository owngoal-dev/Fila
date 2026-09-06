import AlertController
import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Chooses a directory through the same backend as the browser. Files providers
/// cannot represent the root filesystem this app is browsing.
final class SaveDestinationViewController: UIViewController {
    private final class Selection {
        var folderName: String?
        let message: String?
        /// Files are listed too and tapping one is the answer; the checkmark
        /// still answers with the folder being shown. For a symlink target.
        let picksFiles: Bool
        let fileTypes: Set<String>?
        let confirm: (URL) -> Void

        init(folderName: String?, message: String?, picksFiles: Bool, fileTypes: Set<String>? = nil, confirm: @escaping (URL) -> Void) {
            self.folderName = folderName
            self.message = message
            self.picksFiles = picksFiles
            self.fileTypes = fileTypes
            self.confirm = confirm
        }
    }

    private enum Availability { case ready, unavailable, creatingFolder }

    private let directory: URL
    private let link: DaemonLink
    private let selection: Selection
    private let pathBar = PathBarView()
    private let list = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .plain))
    )
    private let rowCell = UICollectionView.CellRegistration<IconRowCell, FileNode> { cell, _, node in cell.configure(node) }
    private let nameField = UITextField()
    private var folders: [FileNode] = []
    private var work: Task<Void, Never>?
    private var availability: Availability = .unavailable

    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(cancel))
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()
    private lazy var confirmItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(commit))
        item.accessibilityLabel = selection.picksFiles ? String(localized: "Choose This Folder") : String(localized: "Save Here")
        return item
    }()
    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()

    convenience init(directory: URL, folderName: String? = nil, message: String? = nil, picksFiles: Bool = false, fileTypes: Set<String>? = nil, link: DaemonLink, confirm: @escaping (URL) -> Void) {
        self.init(directory: directory, link: link, selection: Selection(folderName: folderName, message: message, picksFiles: picksFiles || fileTypes != nil, fileTypes: fileTypes, confirm: confirm), isRoot: true)
    }

    private init(directory: URL, link: DaemonLink, selection: Selection, isRoot: Bool = false) {
        self.directory = directory
        self.link = link
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
        title = selection.fileTypes != nil ? String(localized: "Choose Audio File")
            : selection.picksFiles ? String(localized: "Choose Link Target") : String(localized: "Save To")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.leftBarButtonItem = isRoot ? cancelItem : nil
        refreshActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { work?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pathBar.setPath(directory.path)
        pathBar.onSelect = { [weak self] path in self?.showAncestor(URL(fileURLWithPath: path, isDirectory: true)) }

        list.do {
            $0.delegate = self
            $0.dataSource = self
            $0.keyboardDismissMode = .onDrag
            $0.contentInsetAdjustmentBehavior = .never
        }

        let stack = UIStackView(arrangedSubviews: [pathBar, list])
        stack.axis = .vertical
        view.addSubview(stack)
        if selection.folderName != nil || selection.message != nil {
            let form = UIStackView().then {
                $0.axis = .vertical
                $0.spacing = FilaUI.Spacing.small
                $0.isLayoutMarginsRelativeArrangement = true
                $0.directionalLayoutMargins = .init(top: FilaUI.Spacing.medium, leading: FilaUI.Spacing.large, bottom: FilaUI.Spacing.medium, trailing: FilaUI.Spacing.large)
                $0.backgroundColor = .secondarySystemBackground
            }
            if selection.folderName != nil {
                nameField.do {
                    $0.placeholder = String(localized: "Folder name")
                    $0.accessibilityLabel = String(localized: "Folder name")
                    $0.font = .preferredFont(forTextStyle: .body)
                    $0.adjustsFontForContentSizeCategory = true
                    $0.borderStyle = .roundedRect
                    $0.autocapitalizationType = .none
                    $0.autocorrectionType = .no
                    $0.smartQuotesType = .no
                    $0.smartDashesType = .no
                    $0.clearButtonMode = .whileEditing
                    $0.returnKeyType = .done
                    $0.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
                    $0.addTarget(self, action: #selector(commit), for: .editingDidEndOnExit)
                }
                nameField.snp.makeConstraints { make in
                    make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
                }
                form.addArrangedSubview(nameField)
            }
            if let message = selection.message {
                let note = UILabel().then {
                    $0.text = message
                    $0.font = .preferredFont(forTextStyle: .footnote)
                    $0.adjustsFontForContentSizeCategory = true
                    $0.textColor = .secondaryLabel
                    $0.numberOfLines = 0
                }
                form.addArrangedSubview(note)
            }
            stack.addArrangedSubview(form)
            let formBackground = UIView()
            formBackground.backgroundColor = .secondarySystemBackground
            view.insertSubview(formBackground, belowSubview: stack)
            formBackground.snp.makeConstraints { make in
                make.top.equalTo(form.snp.top)
                make.leading.trailing.bottom.equalToSuperview()
            }
        }
        pathBar.snp.makeConstraints { make in
            make.height.equalTo(FilaUI.minimumTapTarget)
        }
        stack.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nameField.text = selection.folderName
        refreshActions()
    }

    private func refreshActions() {
        confirmItem.isEnabled = availability == .ready && (selection.folderName.map(Self.isValidName) ?? true)
        cancelItem.isEnabled = availability != .creatingFolder
        menuItem.isEnabled = availability != .creatingFolder
        menuItem.menu = UIMenu(children: [
            UIAction(title: String(localized: "New Folder"), image: UIImage(systemName: "folder.badge.plus"), attributes: availability == .ready ? [] : .disabled) { [weak self] _ in
                self?.promptNewFolder()
            },
            UIAction(title: String(localized: "Refresh"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.load() },
            UIAction(title: String(localized: "Cancel"), image: UIImage(systemName: "xmark")) { [weak self] _ in self?.cancel() },
        ])
        navigationItem.rightBarButtonItems = selection.fileTypes == nil ? [confirmItem, menuItem] : [menuItem]
        navigationItem.hidesBackButton = availability == .creatingFolder
        list.isUserInteractionEnabled = availability != .creatingFolder
        pathBar.isUserInteractionEnabled = availability != .creatingFolder
        nameField.isEnabled = availability != .creatingFolder
        if navigationController?.topViewController === self {
            navigationController?.isModalInPresentation = availability == .creatingFolder
            navigationController?.interactivePopGestureRecognizer?.isEnabled = availability != .creatingFolder
        }
    }

    private func load() {
        work?.cancel()
        availability = .unavailable
        folders = []
        list.reloadData()
        list.backgroundView = StatusView(content: .loading(String(localized: "Reading Folder…")))
        refreshActions()
        let link = link
        let path = directory.path
        work = Task { [weak self] in
            do {
                var cursor: UInt64 = 0
                repeat {
                    let page = try await link.list(directory: path, cursor: cursor)
                    guard !Task.isCancelled, let self else { return }
                    let picksFiles = self.selection.picksFiles
                    self.folders.append(contentsOf: page.entries.filter { node in
                        if node.isNavigable { return true }
                        if let types = self.selection.fileTypes {
                            return node.kind == .regular && types.contains((node.name as NSString).pathExtension.lowercased())
                        }
                        return picksFiles
                    })
                    self.folders.sort {
                        $0.isNavigable != $1.isNavigable ? $0.isNavigable : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    self.list.reloadData()
                    self.availability = .ready
                    if !self.folders.isEmpty { self.list.backgroundView = nil }
                    else if page.cursor == 0 {
                        let title: String
                        if self.selection.fileTypes != nil { title = String(localized: "No Audio Files") }
                        else { title = picksFiles ? String(localized: "Folder Is Empty") : String(localized: "No Folders") }
                        self.list.backgroundView = StatusView(content: .message(
                            symbol: "folder", title: title
                        ))
                    }
                    self.refreshActions()
                    cursor = page.cursor
                } while cursor != 0
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.availability = .unavailable
                self.folders = []
                self.list.reloadData()
                self.list.backgroundView = StatusView(content: .message(symbol: "exclamationmark.triangle", title: String(localized: "Unable to Read Folder"), detail: FailureMessage.text(for: error)))
                self.refreshActions()
            }
        }
    }

    private func showAncestor(_ url: URL) {
        view.endEditing(true)
        guard let navigation = navigationController else { return }
        if let existing = navigation.viewControllers.first(where: { ($0 as? SaveDestinationViewController)?.directory.path == url.path }) {
            navigation.popToViewController(existing, animated: true)
        } else {
            navigation.setViewControllers([SaveDestinationViewController(directory: url, link: link, selection: selection, isRoot: true)], animated: false)
        }
    }

    private func open(_ url: URL) {
        view.endEditing(true)
        navigationController?.pushViewController(SaveDestinationViewController(directory: url, link: link, selection: selection), animated: true)
    }

    @objc private func nameChanged() {
        selection.folderName = nameField.text ?? ""
        refreshActions()
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func promptNewFolder() {
        let alert = AlertInputViewController(
            title: "New Folder",
            message: "The folder is created in the current location.",
            placeholder: "Folder name",
            text: "",
            doneButtonText: "Create"
        ) { [weak self] name in
            guard let self else { return }
            guard Self.isValidName(name) else {
                self.showError(String(localized: "Enter a folder name without slashes. “.” and “..” cannot be used."))
                return
            }
            self.createFolder(named: name)
        }
        present(alert, animated: true)
    }

    private func createFolder(named name: String) {
        work?.cancel()
        availability = .creatingFolder
        refreshActions()
        let url = directory.appendingPathComponent(name, isDirectory: true)
        let link = link
        work = Task { [weak self] in
            do {
                try await link.create(.directory, at: url.path)
                guard let self else { return }
                self.load()
                if self.viewIfLoaded?.window != nil, self.navigationController?.topViewController === self { self.open(url) }
            } catch {
                guard let self else { return }
                self.availability = .ready
                self.refreshActions()
                self.showError(FailureMessage.text(for: error, whileWriting: true))
            }
        }
    }

    private func showError(_ message: String) {
        let alert = AlertViewController(title: "Unable to Create Folder", message: message) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func commit() {
        guard selection.fileTypes == nil, confirmItem.isEnabled else { return }
        confirmItem.isEnabled = false
        work?.cancel()
        let destination = selection.folderName.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        dismiss(animated: true) { [selection] in selection.confirm(destination) }
    }
}

extension SaveDestinationViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int { folders.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: folders[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let node = folders[indexPath.item]
        guard node.isNavigable else {
            // A file is a leaf: tapping it is the choice.
            work?.cancel()
            let chosen = directory.appendingPathComponent(node.name, isDirectory: false)
            dismiss(animated: true) { [selection] in selection.confirm(chosen) }
            return
        }
        open(directory.appendingPathComponent(node.name, isDirectory: true))
    }
}
