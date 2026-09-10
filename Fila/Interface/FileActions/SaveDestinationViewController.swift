import AlertController
import FilaBackendUI
import FilaClient
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Chooses a directory through the same backend as the browser. Files providers
/// cannot represent the root filesystem this app is browsing.
final class SaveDestinationViewController: UIViewController {
    private final class Selection {
        var name: String?
        let namesFile: Bool
        let message: String?
        /// Files are listed too and tapping one is the answer; the checkmark
        /// still answers with the folder being shown. For a symlink target.
        let picksFiles: Bool
        let fileTypes: Set<String>?
        let confirm: (URL) -> Void

        init(
            folderName: String?,
            fileName: String?,
            message: String?,
            picksFiles: Bool,
            fileTypes: Set<String>? = nil,
            confirm: @escaping (URL) -> Void
        ) {
            precondition(folderName == nil || fileName == nil)
            name = fileName ?? folderName
            namesFile = fileName != nil
            self.message = message
            self.picksFiles = picksFiles
            self.fileTypes = fileTypes
            self.confirm = confirm
        }
    }

    private enum Availability { case ready, unavailable, creatingFolder }

    private let directory: URL
    private let link: any LocalFileAccess
    private let selection: Selection
    private let pathBar = PathBarView()
    private let list = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(
            using: UICollectionLayoutListConfiguration(appearance: .plain)
        )
    )
    private let rowCell = UICollectionView.CellRegistration<IconRowCell, FileNode> { cell, _, node in
        cell.configure(node)
    }

    private let nameField = UITextField()
    private var folders: [FileNode] = []
    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, String>(
        collectionView: list
    ) { [weak self] list, indexPath, name in
        guard let self, let node = folders.first(where: { $0.name == name }) else { return nil }
        return list.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: node)
    }
    private var work: Task<Void, Never>?
    private var availability: Availability = .unavailable

    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(cancel)
        )
        item.accessibilityLabel = String(localized: "Cancel")
        return item
    }()

    private lazy var confirmItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(commit)
        )
        item.accessibilityLabel = selection.picksFiles
            ? String(localized: "Choose This Folder")
            : String(localized: "Save Here")
        return item
    }()

    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()

    convenience init(
        directory: URL? = nil,
        folderName: String? = nil,
        fileName: String? = nil,
        message: String? = nil,
        picksFiles: Bool = false,
        fileTypes: Set<String>? = nil,
        link: any LocalFileAccess,
        confirm: @escaping (URL) -> Void
    ) {
        self.init(
            directory: directory ?? URL(fileURLWithPath: FileSession.shared.lastDirectoryPath, isDirectory: true),
            link: link,
            selection: Selection(
                folderName: folderName,
                fileName: fileName,
                message: message,
                picksFiles: picksFiles || fileTypes != nil,
                fileTypes: fileTypes,
                confirm: confirm
            ),
            isRoot: true
        )
    }

    private init(directory: URL, link: any LocalFileAccess, selection: Selection, isRoot: Bool = false) {
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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit { work?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(filesChanged),
            name: .filaJobFinished,
            object: nil
        )
        list.refreshControl = UIRefreshControl()
        list.refreshControl?.addTarget(self, action: #selector(filesChanged), for: .valueChanged)
        list.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        pathBar.setCrumbs(PathBarView.localCrumbs(for: directory.path))
        pathBar.onSelect = { [weak self] crumb in
            self?.showAncestor(URL(fileURLWithPath: crumb.target, isDirectory: true))
        }

        list.do {
            $0.delegate = self
            $0.dataSource = dataSource
            $0.keyboardDismissMode = .onDrag
            $0.contentInsetAdjustmentBehavior = .never
        }

        let stack = UIStackView(arrangedSubviews: [pathBar, list])
        stack.axis = .vertical
        view.addSubview(stack)
        if selection.name != nil || selection.message != nil {
            let form = UIStackView().then {
                $0.axis = .vertical
                $0.spacing = FilaUI.Spacing.small
                $0.isLayoutMarginsRelativeArrangement = true
                $0.directionalLayoutMargins = .init(
                    top: FilaUI.Spacing.medium,
                    leading: FilaUI.Spacing.large,
                    bottom: FilaUI.Spacing.medium,
                    trailing: FilaUI.Spacing.large
                )
                $0.backgroundColor = .secondarySystemBackground
            }
            if selection.name != nil {
                nameField.do {
                    $0.placeholder = selection.namesFile ? String(localized: "Name") : String(localized: "Folder name")
                    $0.accessibilityLabel = $0.placeholder
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nameField.text = selection.name
        load()
    }

    @objc private func filesChanged() {
        guard viewIfLoaded?.window != nil else { return }
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        rememberDirectory()
    }

    private func rememberDirectory() {
        guard availability == .ready, viewIfLoaded?.window != nil,
              navigationController?.topViewController === self else { return }
        FileSession.shared.setLastDirectory(directory.path)
    }

    private func refreshActions() {
        confirmItem.isEnabled = availability == .ready && (selection.name.map(Self.isValidName) ?? true)
        cancelItem.isEnabled = availability != .creatingFolder
        menuItem.isEnabled = availability != .creatingFolder
        menuItem.menu = UIMenu(children: FilaMenu.groups([
            UIMenu(
                title: String(localized: "Go"),
                image: UIImage(systemName: "arrow.right.circle"),
                children: FilaMenu.destinations { [weak self] in
                    self?.promptGoToPath()
                } open: { [weak self] path in
                    self?.showAncestor(URL(fileURLWithPath: path, isDirectory: true))
                }
            ),
            UIAction(
                title: String(localized: "New Folder"),
                image: UIImage(systemName: "folder.badge.plus"),
                attributes: availability == .ready ? [] : .disabled
            ) { [weak self] _ in
                self?.promptNewFolder()
            },
        ], [
            UIAction(title: String(localized: "Cancel"), image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.cancel()
            },
        ]))
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
        if dataSource.snapshot().sectionIdentifiers.isEmpty {
            list.backgroundView = StatusView(content: .loading(String(localized: "Reading Folder…")))
        }
        refreshActions()
        let link = link
        let path = directory.path
        work = Task { [weak self] in
            do {
                var cursor: UInt64 = 0
                var received: [FileNode] = []
                repeat {
                    let page = try await link.list(directory: path, cursor: cursor)
                    guard !Task.isCancelled, let self else { return }
                    let picksFiles = selection.picksFiles
                    received.append(contentsOf: page.entries.filter { node in
                        if node.isNavigable {
                            return true
                        }
                        if let types = self.selection.fileTypes {
                            return node.kind == .regular
                                && types.contains((node.name as NSString).pathExtension.lowercased())
                        }
                        return picksFiles
                    })
                    cursor = page.cursor
                } while cursor != 0
                guard let self, !Task.isCancelled else { return }
                folders = received.sorted {
                    $0.isNavigable != $1.isNavigable
                        ? $0.isNavigable
                        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(folders.map(\.name))
                let existing = Set(dataSource.snapshot().itemIdentifiers)
                snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
                await dataSource.apply(snapshot, animatingDifferences: true)
                guard !Task.isCancelled else { return }
                list.refreshControl?.endRefreshing()
                availability = .ready
                rememberDirectory()
                if !folders.isEmpty {
                    list.backgroundView = nil
                } else {
                    let title: String = if selection.fileTypes != nil {
                        String(localized: "No audio files. Choose a different folder.")
                    } else {
                        selection.picksFiles ? String(localized: "This folder is empty. You can still choose it.") : String(localized: "No subfolders. You can still save here.")
                    }
                    list.backgroundView = StatusView(content: .message(symbol: "folder", title: title))
                }
                refreshActions()
            } catch {
                guard !Task.isCancelled, let self else { return }
                list.refreshControl?.endRefreshing()
                availability = .unavailable
                guard folders.isEmpty else { refreshActions(); return }
                list.backgroundView = StatusView(content: .message(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Unable to Read Folder"),
                    detail: FailureMessage.text(for: error)
                ))
                refreshActions()
            }
        }
    }

    private func showAncestor(_ url: URL) {
        view.endEditing(true)
        guard let navigation = navigationController else { return }
        if let existing = navigation.viewControllers.first(where: {
            ($0 as? SaveDestinationViewController)?.directory.path == url.path
        }) {
            navigation.popToViewController(existing, animated: true)
        } else {
            navigation.setViewControllers(
                [SaveDestinationViewController(directory: url, link: link, selection: selection, isRoot: true)],
                animated: false
            )
        }
    }

    private func open(_ url: URL) {
        view.endEditing(true)
        navigationController?.pushViewController(
            SaveDestinationViewController(directory: url, link: link, selection: selection),
            animated: true
        )
    }

    @objc private func nameChanged() {
        selection.name = nameField.text ?? ""
        refreshActions()
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func promptNewFolder() {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("New Folder"),
            message: String.LocalizationValue("The folder is created in the current location."),
            placeholder: String.LocalizationValue("Folder name"),
            text: "",
            doneButtonText: String.LocalizationValue("Create")
        ) { [weak self] name in
            guard let self else { return }
            guard Self.isValidName(name) else {
                showError(String(localized: "Enter a folder name without slashes. “.” and “..” cannot be used."))
                return
            }
            createFolder(named: name)
        }
        present(alert, animated: true)
    }

    private func promptGoToPath() {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Go to Path"),
            message: String.LocalizationValue("Enter an absolute path, starting with a slash."),
            placeholder: .noPlaceholder,
            text: directory.path,
            doneButtonText: String.LocalizationValue("Go")
        ) { [weak self] path in
            guard let self, path.hasPrefix("/") else { return }
            showAncestor(URL(fileURLWithPath: path, isDirectory: true))
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
                load()
                if viewIfLoaded?.window != nil, navigationController?.topViewController === self {
                    open(url)
                }
            } catch {
                guard let self else { return }
                availability = .ready
                refreshActions()
                showError(FailureMessage.text(for: error, whileWriting: true))
            }
        }
    }

    private func showError(_ message: String) {
        let alert = AlertViewController(
            title: String(localized: "Unable to Create Folder"),
            message: message
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func commit() {
        guard selection.fileTypes == nil, confirmItem.isEnabled else { return }
        confirmItem.isEnabled = false
        work?.cancel()
        let destination = selection.name
            .map { directory.appendingPathComponent($0, isDirectory: !selection.namesFile) } ?? directory
        dismiss(animated: true) { [selection] in selection.confirm(destination) }
    }
}

extension SaveDestinationViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let name = dataSource.itemIdentifier(for: indexPath),
              let node = folders.first(where: { $0.name == name }) else { return }
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
