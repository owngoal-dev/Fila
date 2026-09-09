import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import UIKit

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

    func progressCard(title: String, message: String, from presenter: UIViewController) -> any BackendProgressCard {
        DelayedProgressCard(title: title, message: message, presenter: presenter)
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
        }
    }

    func open(_ location: BackendLocation) {
        guard let screen = SidebarLocation.screen(for: location) else { return }
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }?.rootViewController?.shell?.replace(screen)
    }

    var clipboard: BackendClipboardSummary? {
        let clipboard = FileClipboard.shared
        guard !clipboard.isEmpty else { return nil }
        return BackendClipboardSummary(count: clipboard.items.count, isCut: clipboard.isCut, isPasting: clipboard.isPasting)
    }

    func takeToClipboard(_ items: [FileLocation], cut: Bool) {
        FileClipboard.shared.take(items, cut: cut)
    }

    func paste(into destination: FileLocation, from presenter: UIViewController) {
        ClipboardPaste.paste(into: destination, from: presenter)
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

/// The delayed progress card, as the app shows one: presented only once
/// the work has taken a moment, with Cancel, dismissed by whoever asked.
@MainActor
private final class DelayedProgressCard: BackendProgressCard {
    private let card: AlertProgressIndicatorViewController
    private weak var presenter: UIViewController?
    private var reveal: Task<Void, Never>?
    private var dismissed = false

    init(title: String, message: String, presenter: UIViewController) {
        card = AlertProgressIndicatorViewController(title: title, message: message)
        self.presenter = presenter
        reveal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000)) } catch { return }
            guard let self, !dismissed, let presenter = self.presenter,
                  presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
            presenter.present(card, animated: true)
        }
    }

    func update(message: String) {
        card.progressContext.purpose(message: message)
    }

    func dismiss() {
        dismissed = true
        reveal?.cancel()
        guard card.presentingViewController != nil else { return }
        card.dismiss(animated: true)
    }
}
