import AlertController
import FilaClient
import FilaFormats
import FilaProtocol
import FilaTerminal
import UIKit

/// File menus share one implementation; the presenting screen owns navigation.
@MainActor
final class FileActions {
    weak var presenter: UIViewController?
    private let directory: String
    let didRemove: () -> Void
    var session: FileSession {
        .shared
    }

    init(presenter: UIViewController, directory: String, didRemove: @escaping () -> Void = {}) {
        self.presenter = presenter
        self.directory = directory
        self.didRemove = didRemove
    }

    static var deleteTitle: String {
        AppPreferences.shared.usesTrash ? String(localized: "Move to Trash") : String(localized: "Delete Permanently")
    }

    /// Whether `directory` is the trash: where `FileJob` renames deleted items
    /// for the live backend. Compared after resolving links and dropping the
    /// `/private` prefix, so `/var/jb/.fila-trash` and its realpath agree even
    /// though the app cannot stat the directory itself (root-owned 0700).
    static func isTrash(_ directory: String) -> Bool {
        guard let backend = FileSession.shared.hello?.backend else { return false }
        return normalized(directory) == normalized(SidebarLocation.trashDirectory(backend: backend))
    }

    /// A trashed item: a direct child of the trash, wherever it was reached
    /// from — the trash itself, a search with hidden files on, a properties
    /// sheet. Its menu is Put Back or gone for good, and its delete is final.
    static func isInTrash(_ path: String) -> Bool {
        isTrash((path as NSString).deletingLastPathComponent)
    }

    /// Resolves the parent and keeps the last component as written: the trash
    /// may not exist yet, and Foundation leaves a path it cannot stat to the
    /// end unresolved — `/var/jb/.fila-trash` would then never match the
    /// daemon's realpath of the same place.
    private static func normalized(_ path: String) -> String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        let resolved = (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        return resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : resolved
    }

    /// Editors provide their existing unsaved-changes boundary. Reading a path or
    /// opening metadata does not leave editing; file-content actions do.
    func menuElements(
        for path: String,
        node: FileNode,
        additional: [UIMenuElement] = [],
        includesProperties: Bool = true,
        groupsFileOperations: Bool = false,
        preview: (() -> Void)? = nil,
        confirm: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> [UIMenuElement] {
        if Self.isInTrash(path) {
            return trashMenuElements(for: path, additional: additional, confirm: confirm)
        }
        let run: [UIMenuElement] = SystemCapabilities.runsPrograms && Self.canRun(node) ? [UIMenu(
            title: String(localized: "Run"),
            image: UIImage(systemName: "play"),
            children: [
                runAction(path, user: .root, title: String(localized: "Run as root"), confirm: confirm),
                runAction(path, user: .mobile, title: String(localized: "Run as mobile"), confirm: confirm),
            ]
        )] : []
        let properties: [UIMenuElement] = includesProperties ? [
            UIAction(title: String(localized: "Properties"), image: UIImage(systemName: "info.circle")) { [self] _ in
                showProperties(path)
            },
        ] : []
        let install = installAction(path, node: node, confirm: confirm).map { [$0] } ?? []
        let previewActions: [UIMenuElement] = preview.map { open in
            [UIAction(title: String(localized: "Preview"), image: UIImage(systemName: "eye")) { _ in confirm(open) }]
        } ?? []
        // By name alone: a menu is built from a listing row, and sniffing the
        // bytes of every archive-shaped name would be an `open(2)` per row.
        // A name that lies costs one failed job, not a wrong file — but a
        // folder called `Backup.zip` is not an archive under any reading.
        let isArchive = !node.isNavigable && FileFormat.detect(head: Data(), name: node.name) == .archive
        let extraction: [UIMenuElement] = isArchive ? [
            UIAction(
                title: String(localized: "Extract"),
                image: UIImage(systemName: OperationCenter.Kind.extract.symbol)
            ) { [self] _ in
                confirm { self.extract(path) }
            },
        ] : []
        let inspection = additional + previewActions + extraction + properties
        let copy = UIMenu(
            title: String(localized: "Copy"),
            image: UIImage(systemName: "doc.on.doc"),
            children: [
                UIAction(title: String(localized: "File"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    confirm { FileClipboard.shared.take([path], cut: false) }
                },
                UIAction(title: String(localized: "File Name"), image: UIImage(systemName: "textformat")) { _ in
                    UIPasteboard.general.string = (path as NSString).lastPathComponent
                    Toast.show(String(localized: "Copied"))
                },
                UIAction(title: String(localized: "Path"), image: UIImage(systemName: "text.quote")) { _ in
                    UIPasteboard.general.string = path
                    Toast.show(String(localized: "Copied"))
                },
            ]
        )
        let operations: [UIMenuElement] = [
            copy,
            UIAction(title: String(localized: "Move"), image: UIImage(systemName: "scissors")) { _ in
                confirm { FileClipboard.shared.take([path], cut: true) }
            },
            UIAction(title: String(localized: "Rename…"), image: UIImage(systemName: "pencil")) { [self] _ in
                confirm { self.promptRename(path) }
            },
            compressAction(paths: { [path] }, confirm: confirm),
        ]
        let opening: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Open With…"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [self] _ in
                confirm { self.share([path]) }
            },
        ] + run + install
        var destructive: [UIMenuElement] = [
            UIAction(
                title: Self.deleteTitle,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [self] _ in
                confirm { self.delete([path]) }
            },
        ]
        if AppPreferences.shared.allowsGuardOverride {
            destructive.append(UIAction(
                title: String(localized: "Override Protection…"),
                image: UIImage(systemName: "exclamationmark.octagon"),
                attributes: .destructive
            ) { [self] _ in
                confirm { self.promptOverriddenDelete([path]) }
            })
        }
        if groupsFileOperations {
            let file = UIMenu(
                title: String(localized: "File Actions"),
                image: UIImage(systemName: "doc"),
                children: FilaMenu.groups(operations, opening, destructive)
            )
            return FilaMenu.groups(inspection, [file])
        }
        return FilaMenu.groups(inspection, operations, opening, destructive)
    }

    /// A trashed item's menu: back where it came from, or gone for good.
    /// Nothing that opens, copies or renames — the trash is not a folder to
    /// work in, and an item that is wanted goes home first.
    private func trashMenuElements(
        for path: String,
        additional: [UIMenuElement],
        confirm: @escaping (@escaping () -> Void) -> Void
    ) -> [UIMenuElement] {
        [
            UIMenu(
                options: .displayInline,
                children: additional + [
                    UIAction(
                        title: String(localized: "Put Back"),
                        image: UIImage(systemName: "arrow.uturn.backward")
                    ) { [self] _ in
                        confirm { self.putBack([path]) }
                    },
                    UIAction(
                        title: String(localized: "Properties"),
                        image: UIImage(systemName: "info.circle")
                    ) { [self] _ in
                        showProperties(path)
                    },
                ]
            ),
            UIMenu(
                options: .displayInline,
                children: [
                    UIAction(
                        title: String(localized: "Delete Permanently"),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [self] _ in
                        confirm { self.delete([path], permanently: true) }
                    },
                ]
            ),
        ]
    }

    /// Renames each trashed item to the path the trash job wrote on it. The
    /// items that can go home go home; the first refusal is reported after,
    /// and an item without a note gets its own explanation.
    func putBack(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        presenter?.setEditing(false, animated: true)
        // A put back off the trash volume copies the whole file back, which is
        // as long as the delete that put it there. Same card, same reasons.
        let cover = jobCover()
        Task {
            let outcome: Error?
            do {
                try await session.operations.putBack(trashed: paths, started: cover.show)
                outcome = nil
            } catch { outcome = error }
            cover.settle { [self] in
                switch outcome {
                case let failure as FilaFailure where failure.systemError == ENOATTR:
                    let name = failure.path.map { ($0 as NSString).lastPathComponent } ?? ""
                    if let presenter = activePresenter {
                        let alert = AlertViewController(
                            title: String(localized: "Cannot Put Back"),
                            message: String(localized: "The original location of “\(name)” was not recorded. It can only be deleted permanently.")
                        ) { context in
                            context.allowSimpleDispose()
                            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                                context.dispose()
                            }
                        }
                        presenter.present(alert, animated: true)
                    }
                case let error?: report(error)
                case nil: break
                }
                didRemove()
            }
        }
    }

    /// A symlink's own `st_mode` is `0120755` on Darwin, so its execute bits
    /// describe the link, never the target — and `SymbolicLink` carries no
    /// target mode. A link to a program gets no Run entry; it opens as a file.
    private static func canRun(_ node: FileNode) -> Bool {
        node.kind == .regular && node.mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    /// Offered only while `SystemCapabilities.runsPrograms` says so; and without
    /// `filad` the terminal itself refuses, for either identity — see
    /// `DaemonLink.openTerminal` — so nothing here pretends otherwise.
    private func runAction(
        _ path: String,
        user: TerminalUser,
        title: String,
        confirm: @escaping (@escaping () -> Void) -> Void
    ) -> UIAction {
        // Root is marked destructive so the menu itself says which of the two
        // is the one to think about; the terminal spawns as soon as it appears.
        UIAction(title: title, attributes: user == .root ? .destructive : []) { [self] _ in
            confirm { self.openTerminal(.executable(path: path), user: user) }
        }
    }

    @discardableResult
    func openTerminal(
        _ program: TerminalProgram,
        user: TerminalUser,
        onProcessExit: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        guard let presenter = activePresenter else { return false }
        let terminal = TerminalViewController(
            program: program,
            user: user,
            redirectsScriptInterpreter: AppPreferences.shared.redirectsScriptInterpreters,
            link: session.link,
            onProcessExit: onProcessExit
        )
        if let navigation = presenter.navigationController {
            navigation.pushViewController(terminal, animated: true)
        } else if let shell = presenter.shell {
            shell.push(terminal)
        } else {
            return false
        }
        return true
    }

    func showProperties(_ path: String) {
        Task {
            do {
                let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
                guard let presenter = activePresenter else { return }
                presenter.presentAsSheet(UINavigationController(
                    rootViewController: PropertiesViewController(details: details, link: session.link)
                ))
            } catch { report(error) }
        }
    }

    func promptRename(_ path: String) {
        guard let presenter = activePresenter else { return }
        let source = URL(fileURLWithPath: path)
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Rename"),
            message: String.LocalizationValue("Enter a new name. The item stays in the same folder."),
            placeholder: .noPlaceholder,
            text: source.lastPathComponent,
            doneButtonText: String.LocalizationValue("Rename")
        ) { name in
            guard name != source.lastPathComponent else { return }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                self.report(FilaFailure(code: .invalidRequest, systemError: EINVAL, path: name))
                return
            }
            self.rename(
                path,
                to: source.deletingLastPathComponent().appendingPathComponent(name).path,
                replacingExisting: false
            )
        }
        presenter.present(alert, animated: true)
    }

    private func rename(_ source: String, to destination: String, replacingExisting: Bool) {
        Task {
            do {
                try await withSourceLocked {
                    try await session.perform {
                        try await $0.rename(source, to: destination, exclusive: !replacingExisting)
                    }
                }
                NotificationCenter.default.post(name: .filaJobFinished, object: [directory])
                didRemove()
            } catch let failure as FilaFailure where failure.systemError == EEXIST && !replacingExisting {
                confirmDestruction(
                    title: URL(fileURLWithPath: destination).lastPathComponent,
                    message: String(localized: "An item with this name already exists. Replacing it cannot be undone — the replaced item does not go to the trash."),
                    confirm: String(localized: "Replace")
                ) { self.rename(source, to: destination, replacingExisting: true) }
            } catch { report(error) }
        }
    }

    /// *Compress…*: the form, then the job.
    func compressAction(
        paths: @escaping () -> [String],
        confirm: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> UIAction {
        UIAction(title: String(localized: "Compress…"), image: UIImage(systemName: "doc.zipper")) { [self] _ in
            let selection = paths()
            confirm { self.promptCompress(selection) }
        }
    }

    func promptCompress(_ paths: [String]) {
        guard !paths.isEmpty, let presenter = activePresenter else { return }
        let base = paths.count == 1
            ? URL(fileURLWithPath: paths[0]).lastPathComponent
            : "Archive"
        CompressViewController.present(
            from: presenter,
            suggestedName: base.isEmpty ? "Archive" : base,
            directory: directory,
            itemCount: paths.count,
            link: session.link
        ) { [self] choice in
            let suffix = "." + choice.options.format.filenameExtension
            let stem = choice.name.hasSuffix(suffix) ? String(choice.name.dropLast(suffix.count)) : choice.name
            compress(paths, stem: stem, into: choice.directory, options: choice.options)
        }
    }

    /// Starts the daemon job — the work runs in `fila-archive`, or in-process
    /// without a daemon — and covers the screen with its progress.
    func compress(_ paths: [String], stem: String, into directory: String, options: ArchiveOptions) {
        guard !paths.isEmpty else { return }
        presenter?.setEditing(false, animated: true)
        let center = session.operations
        Task {
            do {
                let destination = try await freePath(
                    base: stem,
                    extension: options.format.filenameExtension,
                    in: directory
                )
                let request = JobRequest(kind: .compress, sources: paths, destination: destination, archive: options)
                let identifier = try await center.startJob(
                    request,
                    kind: .compress,
                    title: OperationCenter.Kind.compress.runningTitle,
                    subtitle: OperationCenter.describe(paths, destination: directory)
                )
                guard let operation = center.operation(forJob: identifier),
                      let presenter = activePresenter else { return }
                OperationCoverViewController.present(for: operation.id, from: presenter, center: center)
            } catch { report(error) }
        }
    }

    /// The helper publishes one item directly, or groups multiple top-level
    /// items in a folder. An encrypted archive asks for its password, and the
    /// archive browser is where that question gets asked.
    func extract(_ path: String) {
        presenter?.setEditing(false, animated: true)
        let directory = (path as NSString).deletingLastPathComponent
        let center = session.operations
        Task {
            do {
                let identifier = try await center.startJob(
                    // Options are not optional for an archive job — the helper
                    // refuses one without them. Nil members is every member.
                    JobRequest(
                        kind: .extract,
                        sources: [path],
                        destination: directory,
                        archive: ArchiveOptions(organizeExtraction: true)
                    ),
                    kind: .extract,
                    title: OperationCenter.Kind.extract.runningTitle,
                    subtitle: OperationCenter.describe([path], destination: directory)
                )
                guard let operation = center.operation(forJob: identifier),
                      let presenter = activePresenter else { return }
                OperationCoverViewController.present(for: operation.id, from: presenter, center: center)
            } catch { report(error) }
        }
    }

    func share(_ paths: [String]) {
        guard let first = paths.first else { return }
        presenter?.setEditing(false, animated: true)
        Task {
            do {
                let url = try await session.stage(first)
                let directory = url.deletingLastPathComponent()
                guard let presenter = activePresenter else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: directory)
                }
                presenter.anchor(sheet, to: presenter.view)
                presenter.present(sheet, animated: true)
            } catch { report(error) }
        }
    }

    /// Keep an editor from accepting new changes while its file is renamed or
    /// deleted. Navigation may continue; completion never owns a newer screen.
    func withSourceLocked<T>(_ body: () async throws -> T) async rethrows -> T {
        let presenter = presenter
        let enabled = presenter?.view.isUserInteractionEnabled ?? true
        let buttons = (presenter?.navigationItem.rightBarButtonItems ?? []).map { ($0, $0.isEnabled) }
        presenter?.view.endEditing(true)
        presenter?.view.isUserInteractionEnabled = false
        buttons.forEach { $0.0.isEnabled = false }
        defer {
            presenter?.view.isUserInteractionEnabled = enabled
            buttons.forEach { $0.0.isEnabled = $0.1 }
        }
        return try await body()
    }

    /// The delayed progress card for whatever job this action is about to
    /// start. It reads `activePresenter` at the moment the job exists, not now.
    func jobCover() -> JobCover {
        JobCover(center: session.operations) { [weak self] in self?.activePresenter }
    }

    var activePresenter: UIViewController? {
        guard let presenter, presenter.viewIfLoaded?.window != nil,
              presenter.navigationController?.topViewController === presenter else { return nil }
        var ancestor: UIViewController? = presenter
        while let controller = ancestor {
            guard controller.presentedViewController == nil, !controller.isBeingDismissed else { return nil }
            ancestor = controller.parent
        }
        return presenter
    }

    func confirmDestruction(title: String, message: String, confirm: String, handler: @escaping () -> Void) {
        guard let presenter = activePresenter else { return }
        let alert = AlertViewController(title: title, message: message) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: confirm, attribute: .accent) {
                context.dispose { handler() }
            }
        }
        presenter.present(alert, animated: true)
    }

    func report(_ error: Error) {
        if let failure = error as? FilaFailure, failure.code == .success || failure.code == .cancelled {
            return
        }
        if error is CancellationError {
            return
        }
        guard let presenter = activePresenter else {
            FeedbackAlert.show(String(localized: "Operation Failed"), message: FailureMessage.text(for: error))
            return
        }
        if let failure = error as? FilaFailure {
            presenter.report(failure); return
        }
        let alert = AlertViewController(
            title: String(localized: "Operation Failed"),
            message: FailureMessage.text(for: error)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        presenter.present(alert, animated: true)
    }

    /// The first name this directory does not already hold. An empty extension
    /// is the extraction folder; anything else is the archive being written.
    private func freePath(base: String, extension suffix: String, in directory: String) async throws -> String {
        let dot = suffix.isEmpty ? "" : ".\(suffix)"
        for index in 1 ... Int.max {
            try Task.checkCancellation()
            let name = index == 1 ? "\(base)\(dot)" : "\(base) \(index)\(dot)"
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
            do {
                _ = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: candidate) }
            } catch let failure as FilaFailure where failure.code == .notFound {
                return candidate
            }
        }
        throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: directory)
    }
}
