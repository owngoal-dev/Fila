import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import UIKit
import UniformTypeIdentifiers

/// What module screens borrow from the app: a browser for a location, the
/// destination pickers, staging and jobs through the one operation centre,
/// and the feedback chrome. Assigned once at launch; there is no second
/// implementation and no module builds these for itself.
@MainActor
final class AppBackendShell: BackendShell {
    private var session: FileSession { .shared }

    func browser(for location: BackendLocation) -> UIViewController? {
        guard let backend = BackendComposition.backends.first(where: { $0.id == location.backend }) as? LocalFileBackend,
              let path = try? ServicePath(location.item)
        else { return nil }
        return FileBrowserViewController(directory: backend.absolutePath(path))
    }

    func filePicker(fileTypes: Set<String>?, chosen: @escaping (URL) -> Void) -> UIViewController {
        let picker = SaveDestinationViewController(picksFiles: true, fileTypes: fileTypes, link: session.link, confirm: chosen)
        return UINavigationController(rootViewController: picker)
    }

    func saveDestinationPicker(fileName: String, chosen: @escaping (URL) -> Void) -> UIViewController {
        let picker = SaveDestinationViewController(fileName: fileName, link: session.link, confirm: chosen)
        return UINavigationController(rootViewController: picker)
    }

    func presentSheet(_ controller: UIViewController, from presenter: UIViewController) {
        presenter.presentAsSheet(controller)
    }

    func stage(_ path: String) async throws -> URL {
        try await session.stage(path)
    }

    func copy(_ source: URL, into directory: String, subtitle: String) async throws {
        let result = try await session.operations.awaitJob(
            JobRequest(kind: .copy, sources: [source.path], destination: directory),
            kind: .copy,
            subtitle: subtitle,
            feedback: .silent
        )
        guard result.code == .success else { throw result }
    }

    func delete(_ path: String, subtitle: String) async throws {
        let result = try await session.operations.awaitJob(
            JobRequest(kind: .delete, sources: [path]),
            kind: .delete,
            subtitle: subtitle,
            feedback: .silent
        )
        guard result.code == .success || result.systemError == ENOENT else { throw result }
    }

    func toast(_ text: String) {
        Toast.show(text)
    }

    func alert(title: String, message: String) {
        FeedbackAlert.show(title, message: message)
    }

    func confirmPermanentDeletion(
        from presenter: UIViewController,
        title: String,
        message: String,
        confirmTitle: String,
        confirmed: @escaping () -> Void
    ) {
        PermanentDeleteConfirmation.present(
            from: presenter, title: title, message: message, confirmTitle: confirmTitle, confirm: confirmed
        )
    }

    func failureText(for error: Error) -> String {
        FailureMessage.text(for: error)
    }

    func makeWorkspace() async throws -> URL {
        try await session.makeTemporaryDirectory()
    }

    func fileIcon(named name: String, isDirectory: Bool) -> UIImage? {
        FilePresentation.image(kind: isDirectory ? .directory : .regular, name: name)
    }

    func rootArtwork(for root: BackendRoot) -> UIImage? {
        SidebarLocation.image(for: root)
    }

    func withProgress<T: Sendable>(
        title: String,
        message: String,
        cancellable: Bool,
        from presenter: UIViewController,
        operation: @escaping @MainActor (_ update: @escaping @MainActor (String) -> Void) async throws -> T
    ) async throws -> T {
        try await ProgressCard.run(title: title, message: message, cancellable: cancellable, from: presenter, operation: operation)
    }

    /// The app's own viewer over the snapshot, chosen by format like any
    /// local file. Whatever screen the open put on top — pushed or
    /// presented — carries the release with it; an open that showed
    /// nothing releases at once.
    func preview(_ file: URL, title: String, from presenter: UIViewController, released: @escaping () -> Void) {
        Task { @MainActor in
            await presenter.openFile(at: file.path, session: session)
            let shown: UIViewController?
            if let top = presenter.navigationController?.topViewController, top !== presenter {
                shown = top
            } else if let presented = presenter.presentedViewController {
                shown = presented
            } else {
                shown = nil
            }
            guard let shown else {
                released()
                return
            }
            ReleaseOnDeinit.attach(to: shown, released)
            // The snapshot sits in a workspace nobody should see: the viewer
            // continues the share's crumbs with the file, and a crumb on the
            // share's folders does what it does on the share's screen.
            if let content = shown as? TabContentViewController, let source = presenter as? TabContentViewController {
                content.decorationSource = DetailDecoration(
                    parent: source, title: title, target: file.path, icon: fileIcon(named: title, isDirectory: false)
                )
            }
        }
    }

    func open(_ location: BackendLocation) {
        guard let screen = SidebarLocation.screen(for: location) else { return }
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }?.rootViewController?.shell?.replace(screen)
    }

    /// Over whatever is on top of the page's window: a page's More can be on
    /// a sheet (Properties), and an iPad can have two windows.
    func presentSettings(from presenter: UIViewController) {
        TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
            guard !Self.shows(SettingsViewController.self, top) else { return }
            top.presentSettings()
        }
    }

    /// Whether `top` is already the sheet of that screen: a second tap while
    /// it was on its way must not stack another.
    private static func shows(_ screen: UIViewController.Type, _ top: UIViewController) -> Bool {
        (top as? UINavigationController)?.viewControllers.first.map { type(of: $0) == screen } == true
    }

    var clipboard: BackendClipboardSummary? {
        let clipboard = FileClipboard.shared
        guard !clipboard.isEmpty else { return nil }
        return BackendClipboardSummary(count: clipboard.items.count, isCut: clipboard.isCut, isPasting: clipboard.isPasting)
    }

    func takeToClipboard(_ items: [FileLocation], cut: Bool) {
        FileClipboard.shared.take(items, cut: cut)
    }

    func paste(into destination: FileLocation, mode: TransferMode, from presenter: UIViewController) {
        ClipboardPaste.paste(into: FileReference(destination), mode: mode, from: presenter)
    }

    func presentClipboard(from presenter: UIViewController) {
        let session = session
        TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
            guard !Self.shows(ClipboardViewController.self, top) else { return }
            let controller = ClipboardViewController(clipboard: .shared)
            controller.onReveal = { [weak top] item in
                if item.backend == session.local.id {
                    top?.shell?.follow(.reveal(session.local.absolutePath(item.path)))
                } else if let parent = item.path.parent,
                          let screen = SidebarLocation.screen(for: BackendLocation(backend: item.backend, item: parent.description))
                {
                    // A share's browser has no selection to land on; its
                    // folder is the nearest thing to revealing the entry.
                    top?.shell?.replace(screen)
                }
            }
            top.presentAsSheet(UINavigationController(rootViewController: controller))
        }
    }

    func clearClipboard() {
        FileClipboard.shared.clear()
    }

    func drop(_ items: [UIDragItem], into destination: FileLocation, from presenter: UIViewController) {
        FileDrop.receive(items, into: FileReference(destination), from: presenter)
    }

    func receiveFiles(
        _ items: [UIDragItem],
        conformingTo types: [UTType],
        from presenter: UIViewController,
        _ receive: @escaping @MainActor ([String]) async -> Void
    ) {
        FileDrop.receiveFiles(items, conformingTo: types, from: presenter, receive)
    }
}

/// A snapshot's workspace lives as long as the screen showing it; this
/// rides on that screen and runs the release when it is gone.
private final class ReleaseOnDeinit {
    private static var key = 0
    private let release: () -> Void

    private init(_ release: @escaping () -> Void) {
        self.release = release
    }

    static func attach(to owner: AnyObject, _ release: @escaping () -> Void) {
        objc_setAssociatedObject(owner, &key, ReleaseOnDeinit(release), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    deinit {
        release()
    }
}
