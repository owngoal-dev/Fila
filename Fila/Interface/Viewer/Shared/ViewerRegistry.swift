import AlertController
import FilaClient
import FilaFormats
import FilaProtocol
import SnapKit
import UIKit

/// The seam between the browser and everything that opens a file.
///
/// The browser knows this one function and nothing else about viewers, so
/// adding a format is adding a file here — never a change to the list. That is
/// the whole reason the registry exists rather than a `switch` in the browser.
enum ViewerRegistry {
    /// The viewer for a file, or nil when there is nothing to open — a
    /// directory, a socket, a device node. Nil is meant to be rare: `FileFormat`
    /// has no "unknown" case because the hex viewer is the floor and every file
    /// has one.
    ///
    /// Prepare the selected viewer and its navigation items before the caller
    /// pushes it. Format detection must not add editor buttons mid-transition.
    @MainActor
    static func makeViewer(for details: FileDetails, link: DaemonLink) async -> UIViewController? {
        let kind = details.node.kind == .symbolicLink ? details.node.link?.resolvedKind : details.node.kind
        guard kind == .regular else { return nil }
        let viewer = ViewerContainerViewController(details: details, link: link)
        await viewer.prepare()
        return viewer
    }

    /// The format-to-viewer table. The only place the mapping is written down.
    static func viewer(
        for format: FileFormat,
        details: FileDetails,
        file: DescriptorFile,
        link: DaemonLink
    ) -> UIViewController {
        switch format {
        case .propertyList:
            return PropertyListEditorViewController(details: details, file: file, link: link)
        case .machO:
            return MachOInspectorViewController(details: details, file: file, link: link)
        case .archive:
            return ArchiveBrowserViewController(details: details, file: file, link: link)
        case .image:
            return ImageViewerViewController(details: details, file: file)
        case .audio:
            return MediaPlayerViewController(details: details, file: file, isAudio: true)
        case .video:
            return MediaPlayerViewController(details: details, file: file, isAudio: false)
        case .pdf:
            return PDFViewerViewController(details: details, file: file)
        case .text:
            return TextViewerViewController(details: details, file: file, link: link)
        // A SQLite browser is a viewer several times the size of the others and
        // is deliberately deferred; until it exists the file is bytes, and bytes
        // have a viewer.
        case .sqlite, .binary:
            return HexViewerViewController(details: details, file: file)
        }
    }
}

/// Opens the file once, detects what it is, and hosts the viewer that resulted.
///
/// One descriptor for the whole screen: the container opens it, reads the
/// detection window, and hands ownership to the child. Detecting in one place
/// and opening in another would mean two `open(2)`s per tap, and on a device
/// each one is a round trip to a daemon that may still be launching.
final class ViewerContainerViewController: UIViewController {
    /// Menu entries a child folds into the screen's one menu, above "Open As".
    /// A child sets this rather than adding a second menu button beside this
    /// one: two ellipses in one navigation bar is how a screen ends up with the
    /// same action in two places.
    var childMenuElements: [UIMenuElement] = []
    /// Editors request a visible presenter only when a save/discard prompt is
    /// needed. Closing a clean background tab never needs to display its page.
    var confirmReplacement: ((_ prepareToPresent: () -> Void, _ replace: @escaping () -> Void) -> Void)?

    private let details: FileDetails
    private let link: DaemonLink
    /// Shown until the child is embedded or the open fails, which are the only
    /// two ways `load()` ends.
    private lazy var status = StatusView(content: .loading(
        String(localized: "Opening…"),
        detail: fileName + " · " + FilePresentation.byteLabel(details.node.size)
    ))
    private var child: UIViewController?
    private var detectedFormat: FileFormat?
    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()
    private var fileName: String { (details.path as NSString).lastPathComponent }

    init(details: FileDetails, link: DaemonLink) {
        self.details = details
        self.link = link
        super.init(nibName: nil, bundle: nil)
        title = fileName
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = menuItem
        menuItem.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(status)
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    fileprivate func prepare() async {
        loadViewIfNeeded()
        do {
            let file = try await DescriptorFile.open(details.path, link: link)
            let head = try file.read(at: 0, count: FileFormat.detectionByteCount)
            let format = FileFormat.detect(head: head, name: fileName)
            try present(format: format, file: file)
        } catch {
            present(failure: error)
        }
    }

    private func present(format: FileFormat, file: DescriptorFile) throws {
        try PreviewLimits.validate(byteCount: file.byteCount, format: format)
        detectedFormat = format
        // Cleared before the child loads, because the child sets it while its
        // view is being made and clearing afterwards would wipe it.
        childMenuElements = []
        confirmReplacement = nil
        embed(ViewerRegistry.viewer(for: format, details: details, file: file, link: link))
        refreshBarItems()
        menuItem.isEnabled = true
    }

    private func present(failure: Error) {
        childMenuElements = []
        confirmReplacement = nil
        // Never `localizedDescription`: this is usually a `FilaFailure` from the
        // open, and that type has no `LocalizedError`, so the raw description is
        // "(FilaProtocol.FilaFailure error 1.)" — filling the screen with the
        // one message a user can neither read nor act on.
        embed(ViewerFailureViewController(message: FailureMessage.text(for: failure)))
        refreshBarItems()
        menuItem.isEnabled = true
    }

    private func embed(_ controller: UIViewController) {
        status.removeFromSuperview()

        if let child {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        child = controller
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controller.didMove(toParent: self)
    }

    /// The child owns the screen's title, its buttons and its refusal to be
    /// left; the container is a frame. A child's own navigation item is never
    /// the one the bar reads, so what it puts there is copied here — and a
    /// child whose buttons change calls this again.
    ///
    /// "Open as" is the container's own, and the escape hatch for when
    /// detection guessed wrong, which on a jailbroken filesystem it eventually
    /// will: an extensionless file whose first bytes happen to be printable is
    /// text until someone says otherwise.
    func refreshBarItems() {
        let item = child?.navigationItem
        navigationItem.title = item?.title ?? fileName
        navigationItem.prompt = nil
        let trailingItems = (item?.rightBarButtonItems ?? []) + [menuItem]
        if navigationItem.rightBarButtonItems != trailingItems {
            navigationItem.rightBarButtonItems = trailingItems
        }
        navigationItem.hidesBackButton = item?.hidesBackButton ?? false
        let leadingItems = item?.leftBarButtonItems ?? []
        if let shell, shell.content.visibleTop === self {
            // Compose the child's exit and shell controls in one assignment.
            // Clearing first would remove the prepared Back during viewWillAppear.
            shell.configureSidebarButton(for: self, leadingItems: leadingItems)
        } else if (navigationItem.leftBarButtonItems ?? []) != leadingItems {
            navigationItem.leftBarButtonItems = leadingItems.isEmpty ? nil : leadingItems
        }
        navigationItem.scrollEdgeAppearance = item?.scrollEdgeAppearance
        isModalInPresentation = child?.isModalInPresentation ?? false
        navigationController?.isModalInPresentation = isModalInPresentation
        toolbarItems = child?.toolbarItems
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: false)
        }

        let choices: [FileFormat] = [.text, .binary, .propertyList, .machO, .archive, .image]
        let openAs = UIMenu(
            title: String(localized: "Open As"),
            image: UIImage(systemName: "doc.text.magnifyingglass"),
            options: .singleSelection,
            children: choices.map { format in
                UIAction(
                    title: Self.name(of: format),
                    state: format == detectedFormat ? .on : .off
                ) { [weak self] _ in self?.reopen(as: format) }
            }
        )
        let tabs = UIAction(title: String(localized: "Tabs"), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            self?.shell?.presentTabSwitcher()
        }
        menuItem.menu = UIMenu(children: fileMenuElements(presenting: self, additional: childMenuElements + [openAs]) + FilaMenu.groups([tabs]))
    }

    /// Nested editors and virtual archive directories use their real file's
    /// container; a staged archive member must never borrow another file.
    func fileMenuElements(presenting presenter: UIViewController, additional: [UIMenuElement] = []) -> [UIMenuElement] {
        let directory = URL(fileURLWithPath: details.path).deletingLastPathComponent().path
        let actions = FileActions(presenter: presenter, directory: directory) { [weak self, weak presenter] in
            guard let self, let presenter, let navigation = self.navigationController,
                  navigation.topViewController === presenter,
                  let index = navigation.viewControllers.firstIndex(where: { $0 === self }), index > 0 else { return }
            navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
        }
        let confirmBlock: (@escaping () -> Void) -> Void = { [weak self, weak presenter] action in
            guard let self, self.menuItem.isEnabled else { return }
            let perform = { [weak self, weak presenter] in
                guard let self, let presenter, let navigation = self.navigationController,
                      navigation.topViewController === presenter else { return }
                action()
            }
            if let confirm = self.confirmReplacement { confirm({}, perform) }
            else { perform() }
        }
        return actions.menuElements(
            for: details.path,
            node: details.node,
            additional: additional,
            groupsFileOperations: true,
            confirm: confirmBlock
        )
    }

    private func reopen(as format: FileFormat) {
        guard format != detectedFormat, menuItem.isEnabled else { return }
        let replace: () -> Void = { [weak self] in self?.open(as: format) }
        if let confirmReplacement { confirmReplacement({}, replace) }
        else { replace() }
    }

    private func open(as format: FileFormat) {
        // Once leaving is approved, keep this editor still until the new
        // descriptor arrives. Open after a possible atomic save so the new
        // viewer sees the replacement inode, never a stale pre-save handle.
        view.endEditing(true)
        view.isUserInteractionEnabled = false
        let buttons = (navigationItem.rightBarButtonItems ?? []).map { ($0, $0.isEnabled) }
        for (button, _) in buttons { button.isEnabled = false }
        menuItem.isEnabled = false
        let details = details
        let link = link
        Task { [weak self] in
            defer {
                self?.view.isUserInteractionEnabled = true
                for (button, wasEnabled) in buttons { button.isEnabled = wasEnabled }
            }
            do {
                let file = try await DescriptorFile.open(details.path, link: link)
                try self?.present(format: format, file: file)
            } catch {
                let alert = AlertViewController(
                    title: "Unable to Open This File",
                    message: FailureMessage.text(for: error)
                ) { context in
                    context.allowSimpleDispose()
                    context.addAction(title: "OK", attribute: .accent) {
                        context.dispose()
                    }
                }
                self?.present(alert, animated: true)
            }
        }
    }

    private static func name(of format: FileFormat) -> String {
        switch format {
        case .propertyList: return String(localized: "Property List")
        case .machO: return String(localized: "Mach-O")
        case .archive: return String(localized: "Archive")
        case .image: return String(localized: "Image")
        case .audio: return String(localized: "Audio")
        case .video: return String(localized: "Video")
        case .pdf: return String(localized: "PDF")
        case .sqlite: return String(localized: "Database")
        case .text: return String(localized: "Text")
        case .binary: return String(localized: "Hex")
        }
    }
}

/// What a viewer shows when the file could not be read at all. Not a connection
/// failure — those are never surfaced — but a real refusal from the kernel,
/// which the user can act on by changing a mode or a flag.
final class ViewerFailureViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let status = StatusView(content: .message(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Unable to Open This File"),
            detail: message
        ))
        view.addSubview(status)
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}
