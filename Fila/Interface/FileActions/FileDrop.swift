import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaProtocol
import UIKit
import UniformTypeIdentifiers

/// A drop, onto any screen: the local browser's folders, a share's folders
/// (through `BackendShell.drop`) and the music library (through
/// `BackendShell.receiveFiles`) all end here, and everything they carry goes
/// through `FileDelivery` or the one transfer.
///
/// Both entry points run synchronously as far as asking another app for its
/// files: UIKit wants a drop's item providers asked before `performDrop`
/// returns. What arrives lands in a workspace removed once the drop is done.
@MainActor
enum FileDrop {
    /// Files dragged inside Fila land after one question, Copy or Move; files
    /// from another app are imported, which is always a copy. What is already
    /// in `folder` is left out. Declining the question, or a failed Copy or
    /// Move, drops the whole drop.
    static func receive(_ items: [UIDragItem], into folder: FileReference, from presenter: UIViewController) {
        let dragged = FileReference.dragged(items).filter { !$0.isAlreadyIn(folder) }
        let arrivals = Arrivals(items, conformingTo: [.data])
        Task {
            defer { arrivals.release() }
            if !dragged.isEmpty {
                guard let mode = await askCopyOrMove(into: folder, from: presenter),
                      await FileDelivery.deliver(dragged, into: folder, mode: mode, from: presenter)
                else { return }
            }
            await FileDelivery.importFiles(count: arrivals.files.count, into: folder, from: presenter) { index, _ in
                try await arrivals.files[index]()
            }
        }
    }

    /// The dropped files that are one of `types`, as local paths, for
    /// `receive`: local files where they are, a share's and another app's
    /// copied into the workspace behind the progress card first. Nothing is
    /// called when no file is one of `types`, or on Cancel; a failure is
    /// reported here.
    static func receiveFiles(
        _ items: [UIDragItem],
        conformingTo types: [UTType],
        from presenter: UIViewController,
        _ receive: @escaping @MainActor ([String]) async -> Void
    ) {
        var paths: [String] = []
        var shares: [BackendID: [FileLocation]] = [:]
        for file in FileReference.dragged(items) where file.isFile(of: types) {
            switch file {
            case let .local(path): paths.append(path)
            case let .remote(location): shares[location.backend, default: []].append(location)
            }
        }
        let arrivals = Arrivals(items, conformingTo: types, reserving: !shares.isEmpty)
        guard !paths.isEmpty || !shares.isEmpty || !arrivals.files.isEmpty else { return }
        Task {
            defer { arrivals.release() }
            do {
                let fetched = try await ProgressCard.run(
                    title: String(localized: "Preparing…"),
                    message: String(localized: "Loading the selected file for import."),
                    cancellable: true,
                    from: presenter
                ) { _ in
                    var fetched: [String] = []
                    for locations in shares.values {
                        let folder = try arrivals.folder()
                        try await fetch(locations, into: folder)
                        fetched += locations.map { folder.appendingPathComponent($0.path.name ?? "").path }
                    }
                    for file in arrivals.files {
                        try await fetched.append(file().path)
                    }
                    return fetched
                }
                await receive(paths + fetched)
            } catch {
                FileDelivery.reportImport(error)
            }
        }
    }

    /// A share's files into a local folder, through the one transfer. Not
    /// through `FileDelivery`: that reports its own failure, and an alert
    /// presented from inside the card's work covers the card.
    private static func fetch(_ locations: [FileLocation], into folder: URL) async throws {
        let local = FileSession.shared.local
        guard let path = local.servicePath(forAbsolute: folder.path) else {
            throw FilaFailure(code: .invalidRequest, path: folder.path)
        }
        let outcome = await FileSession.shared.operations.transfer(
            locations, into: FileLocation(backend: local.id, path: path), mode: .copy, policy: .failIfExists
        )
        if let failure = outcome.failure {
            throw outcome.wasCancelled ? CancellationError() : failure
        }
    }

    /// Nil when the card is cancelled or tapped away.
    private static func askCopyOrMove(into folder: FileReference, from presenter: UIViewController) async -> TransferMode? {
        await CardQuestion.ask(whenGone: nil, from: presenter) { reply in
            let alert = AlertViewController(
                title: folder.name,
                message: String(localized: "Copy keeps the originals. Move takes them out of their current folder.")
            ) { context in
                context.allowSimpleDispose()
                context.addAction(title: String.LocalizationValue("Cancel")) { reply(context, nil) }
                context.addAction(title: String.LocalizationValue("Copy Here")) { reply(context, TransferMode.copy) }
                context.addAction(title: String.LocalizationValue("Move Here"), attribute: .accent) { reply(context, TransferMode.move) }
            }
            alert.shouldDismissWhenTappedAround = true
            return alert
        }
    }

    /// Another app's files in a drop, asked for at once, each into a folder of
    /// its own under one workspace, so two of the same name never meet. A file
    /// that could not be asked for fails when it is awaited, on its own.
    @MainActor
    private final class Arrivals {
        private let workspace: Result<URL, Error>
        private var folders = 0
        private(set) var files: [@Sendable () async throws -> URL] = []

        /// `reserving`: a workspace is wanted even with nothing from another
        /// app, for a share's files.
        init(_ items: [UIDragItem], conformingTo types: [UTType], reserving: Bool = false) {
            let providers = items.filter { $0.localObject == nil && $0.itemProvider.fileTypeIdentifier(conformingTo: types) != nil }
                .map(\.itemProvider)
            workspace = providers.isEmpty && !reserving
                ? .failure(FilaFailure(errno: EINVAL))
                : Result { try FileSession.shared.makeTemporaryDirectoryNow() }
            files = providers.map { provider in
                do { return try FileImport.item(provider, conformingTo: types, into: folder()) } catch { return { throw error } }
            }
        }

        func folder() throws -> URL {
            folders += 1
            let folder = try workspace.get().appendingPathComponent(String(folders))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return folder
        }

        /// Dropping a load that has not arrived cancels it.
        func release() {
            files = []
            if case let .success(workspace) = workspace {
                try? FileManager.default.removeItem(at: workspace)
            }
        }
    }
}
