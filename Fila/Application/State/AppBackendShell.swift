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
}
