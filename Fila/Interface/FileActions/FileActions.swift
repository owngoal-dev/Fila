import AlertController
import FilaClient
import FilaFormats
import FilaProtocol
import FilaTerminal
import UIKit

/// File menus share one implementation; the presenting screen owns navigation.
@MainActor
final class FileActions {
    private weak var presenter: UIViewController?
    private let directory: String
    private let didRemove: () -> Void
    private var session: FileSession { .shared }

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

    /// Editors provide their existing save/discard boundary. Reading a path or
    /// opening metadata does not leave editing; file-content actions do.
    func menuElements(
        for path: String, node: FileNode, additional: [UIMenuElement] = [], includesProperties: Bool = true,
        confirm: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> [UIMenuElement] {
        if Self.isInTrash(path) { return trashMenuElements(for: path, additional: additional, confirm: confirm) }
        let run: [UIMenuElement] = SystemCapabilities.runsPrograms && Self.canRun(node) ? [UIMenu(
            title: String(localized: "Run"), image: UIImage(systemName: "play"), children: [
                runAction(path, user: .root, title: String(localized: "Run as root"), confirm: confirm),
                runAction(path, user: .mobile, title: String(localized: "Run as mobile"), confirm: confirm),
            ]
        )] : []
        let properties: [UIMenuElement] = includesProperties ? [
            UIAction(title: String(localized: "Properties"), image: UIImage(systemName: "info.circle")) { [self] _ in showProperties(path) },
        ] : []
        let install = installAction(path, node: node, confirm: confirm).map { [$0] } ?? []
        let file: [UIMenuElement] = properties + run + install + additional + [
            UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                confirm { FileClipboard.shared.take([path], cut: false) }
            },
            UIAction(title: String(localized: "Move"), image: UIImage(systemName: "scissors")) { _ in
                confirm { FileClipboard.shared.take([path], cut: true) }
            },
            UIAction(title: String(localized: "Copy Path"), image: UIImage(systemName: "text.quote")) { _ in
                UIPasteboard.general.string = path
                Toast.show(String(localized: "Copied"))
            },
            UIAction(title: String(localized: "Rename…"), image: UIImage(systemName: "pencil")) { [self] _ in confirm { self.promptRename(path) } },
        ]
        let tools = UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Open With…"), image: UIImage(systemName: "square.and.arrow.up")) { [self] _ in confirm { self.share([path]) } },
            compressAction(paths: { [path] }, confirm: confirm),
        ])
        var destructive: [UIMenuElement] = [
            UIAction(title: Self.deleteTitle, image: UIImage(systemName: "trash"), attributes: .destructive) { [self] _ in confirm { self.delete([path]) } },
        ]
        if AppPreferences.shared.allowsGuardOverride {
            destructive.append(UIAction(title: String(localized: "Override Protection…"), image: UIImage(systemName: "exclamationmark.octagon"), attributes: .destructive) { [self] _ in
                confirm { self.promptOverriddenDelete([path]) }
            })
        }
        return [UIMenu(options: .displayInline, children: file), tools, UIMenu(options: .displayInline, children: destructive)]
    }

    /// A trashed item's menu: back where it came from, or gone for good.
    /// Nothing that opens, copies or renames — the trash is not a folder to
    /// work in, and an item that is wanted goes home first.
    private func trashMenuElements(
        for path: String, additional: [UIMenuElement], confirm: @escaping (@escaping () -> Void) -> Void
    ) -> [UIMenuElement] {
        [
            UIMenu(options: .displayInline, children: additional + [
                UIAction(title: String(localized: "Put Back"), image: UIImage(systemName: "arrow.uturn.backward")) { [self] _ in confirm { self.putBack([path]) } },
                UIAction(title: String(localized: "Properties"), image: UIImage(systemName: "info.circle")) { [self] _ in showProperties(path) },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Delete Permanently"), image: UIImage(systemName: "trash"), attributes: .destructive) { [self] _ in
                    confirm { self.delete([path], permanently: true) }
                },
            ]),
        ]
    }

    /// Renames each trashed item to the path the trash job wrote on it. The
    /// items that can go home go home; the first refusal is reported after,
    /// and an item without a note gets its own explanation.
    func putBack(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        presenter?.setEditing(false, animated: true)
        Task {
            do {
                try await session.operations.putBack(trashed: paths)
            } catch let failure as FilaFailure where failure.systemError == ENOATTR {
                let name = failure.path.map { ($0 as NSString).lastPathComponent } ?? ""
                if let presenter = activePresenter {
                    let alert = AlertViewController(
                        title: "Cannot Put Back",
                        message: String(localized: "Fila has no original location for “\(name)”. Move it out of the trash, or delete it permanently.")
                    ) { context in
                        context.allowSimpleDispose()
                        context.addAction(title: "OK", attribute: .accent) {
                            context.dispose()
                        }
                    }
                    presenter.present(alert, animated: true)
                }
            } catch { report(error) }
            didRemove()
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
    private func runAction(_ path: String, user: TerminalUser, title: String, confirm: @escaping (@escaping () -> Void) -> Void) -> UIAction {
        // Root is marked destructive so the menu itself says which of the two
        // is the one to think about; the terminal spawns as soon as it appears.
        UIAction(title: title, attributes: user == .root ? .destructive : []) { [self] _ in
            confirm { self.openTerminal(.executable(path: path), user: user) }
        }
    }

    @discardableResult
    private func openTerminal(_ program: TerminalProgram, user: TerminalUser,
                              onProcessExit: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard let presenter = activePresenter else { return false }
        let terminal = TerminalViewController(program: program, user: user, link: session.link, onProcessExit: onProcessExit)
        if let navigation = presenter.navigationController {
            navigation.pushViewController(terminal, animated: true)
        } else if let shell = presenter.shell {
            shell.push(terminal)
        } else {
            return false
        }
        return true
    }

    /// One Install… entry, routed by format, each behind a card that says what
    /// is about to happen. A `.deb` runs the bootstrap's `dpkg -i` on a
    /// terminal as root, so it needs the daemon and the Run setting like the
    /// Run menu does. A `.tipa` is TrollStore's format and goes to TrollStore
    /// through the share sheet: installd refuses a fake-signed bundle every
    /// time, so there is nothing to try first (Roadmap → IPA installation).
    /// An `.ipa` goes to installd through `IPAInstaller`, which is the route
    /// AppSync Unified opens; without it the refusal is reported as such.
    private func installAction(_ path: String, node: FileNode, confirm: @escaping (@escaping () -> Void) -> Void) -> UIAction? {
        guard node.kind == .regular else { return nil }
        let name = (path as NSString).lastPathComponent
        let install: () -> Void
        switch (path as NSString).pathExtension.lowercased() {
        case "deb":
            guard SystemCapabilities.runsPrograms else { return nil }
            install = { [self] in promptInstallPackage(path) }
        case "tipa":
            install = { [self] in
                confirmDestruction(
                    title: String(localized: "Open in TrollStore?"),
                    message: String(localized: "Choose TrollStore to install “\(name)” without the system installer."),
                    confirm: String(localized: "Open")
                ) { self.share([path]) }
            }
        case "ipa":
            // A sandboxed build has no InstallCoordination entitlement and
            // would copy the whole package only to be refused; the handshake
            // says which build this is, so the entry waits for it.
            guard let backend = session.hello?.backend, backend != .local(reach: .container) else { return nil }
            install = { [self] in promptInstallApp(path) }
        default:
            return nil
        }
        return UIAction(title: String(localized: "Install…"), image: UIImage(systemName: "arrow.down.app")) { _ in confirm(install) }
    }

    /// Reads the package's identity first, and refuses Fila's own: its postinst
    /// restarts `filad`, and a stopping daemon hangs up every terminal it
    /// spawned — dpkg included, between unpack and configure. That package
    /// goes through the system package manager or the device updater, never a
    /// terminal this daemon owns.
    private func promptInstallPackage(_ path: String) {
        let name = (path as NSString).lastPathComponent
        Task {
            let staged: URL
            do { staged = try await session.stage(path) }
            catch { report(error); return }
            let cleanup: @MainActor @Sendable () -> Void = { [self] in
                do { try FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                catch { report(error) }
            }
            do {
                let manifest = try await DebianPackage.manifest(ofDebAt: staged.path, session: session)
                guard manifest.package != Bundle.main.bundleIdentifier else {
                    throw ViewerFailure.unsupportedContent(String(localized: "“\(name)” is Fila itself and cannot be installed from here. Install it with your package manager."))
                }
                guard let presenter = activePresenter else { cleanup(); return }
                let alert = AlertViewController(
                    title: String(localized: "Install Package?"),
                    message: String(localized: "Installs “\(name)” as root with dpkg. A faulty package can damage the jailbreak or leave the device unable to start. This cannot be undone.")
                ) { context in
                    context.addAction(title: "Cancel") { context.dispose { cleanup() } }
                    context.addAction(title: "Install", attribute: .accent) {
                        context.dispose {
                            if !self.openTerminal(.installPackage(path: staged.path), user: .root, onProcessExit: cleanup) {
                                cleanup()
                            }
                        }
                    }
                }
                presenter.present(alert, animated: true)
            } catch { cleanup(); report(error) }
        }
    }

    /// Keep package confirmations and installs serial across all file screens.
    /// Different paths can contain packages for the same application.
    private static var appInstallInFlight = false

    /// Stages the copy first — the installer consumes what it is handed — and
    /// reads the manifest from that copy, so the card, the install and any
    /// cleanup all describe the same bytes even if the original is replaced
    /// while the card is up.
    private func promptInstallApp(_ path: String) {
        guard !Self.appInstallInFlight else {
            FeedbackAlert.show(String(localized: "App Installation Pending"), message: String(localized: "Wait for the current installation to finish, then try again."))
            return
        }
        Self.appInstallInFlight = true
        Task {
            let progress = await presentProgress(title: "Reading App…")
            let staged: URL
            let manifest: IPAInstaller.Manifest
            do {
                staged = try await session.stage(path)
                do { manifest = try await IPAInstaller.manifest(ofIPAAt: staged) } catch {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    throw error
                }
            } catch {
                await dismiss(progress)
                Self.appInstallInFlight = false
                report(error)
                return
            }
            await dismiss(progress)
            guard let presenter = activePresenter else {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                Self.appInstallInFlight = false
                return
            }
            let alert = AlertViewController(
                title: "Install App?",
                message: String(localized: "The system installer will install “\(manifest.displayName)” (\(manifest.bundleID)), replacing any app with the same identifier. Apps not signed for this device require AppSync Unified.")
            ) { context in
                context.addAction(title: "Cancel") {
                    context.dispose {
                        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                        Self.appInstallInFlight = false
                    }
                }
                context.addAction(title: "Install", attribute: .accent) {
                    context.dispose { Task { await self.installApp(path, staged: staged, manifest: manifest) } }
                }
            }
            presenter.present(alert, animated: true)
        }
    }

    /// A failure does not establish ownership of anything now registered under
    /// the identifier. The system or another installer may have changed it, so
    /// uninstall remains an explicit user action in Applications.
    private func installApp(_ path: String, staged: URL, manifest: IPAInstaller.Manifest) async {
        let progress = await presentProgress(title: "Installing App…")
        let outcome = await IPAInstaller.install(ipaAt: staged, packageType: "Developer")
        // An unanswered request may still be reading its source. Preserve the
        // workspace and keep further requests disabled for this session.
        switch outcome {
        case .timedOut: break
        default:
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            Self.appInstallInFlight = false
        }
        await dismiss(progress)
        switch outcome {
        case .installed:
            Toast.show(String(localized: "App Installed"))
        case .unsupported:
            reportInstallRefusal(
                path,
                message: String(localized: "Fila cannot use the system installer. Open “\(manifest.displayName)” with another installer.")
            )
        case .timedOut:
            report(NSError(domain: "IPAInstaller", code: -1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "The installer is still working. Check Applications before trying again.")
            ]))
        case let .failed(domain, code, message):
            if outcome.isSignatureRefusal {
                reportInstallRefusal(
                    path,
                    message: String(localized: "The signature of “\(manifest.displayName)” was rejected. Install AppSync Unified on this device or open the file in TrollStore.")
                )
            } else {
                report(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
    }

    /// Copying and installing a package is never a blink, so the card shows at
    /// once rather than after the delete path's reveal delay.
    private func presentProgress(title: String.LocalizationValue) async -> AlertProgressIndicatorViewController? {
        guard let presenter = activePresenter else { return nil }
        let progress = AlertProgressIndicatorViewController(title: title, message: "Large packages take time.")
        await withCheckedContinuation { continuation in
            presenter.present(progress, animated: true) { continuation.resume() }
        }
        return progress
    }

    private func dismiss(_ progress: AlertProgressIndicatorViewController?) async {
        guard let progress else { return }
        await withCheckedContinuation { continuation in
            progress.dismiss(animated: true) { continuation.resume() }
        }
    }

    /// A refusal with a way out: the same share sheet the `.tipa` route uses,
    /// where TrollStore (or another installer) is one tap away.
    private func reportInstallRefusal(_ path: String, message: String) {
        guard let presenter = activePresenter else {
            FeedbackAlert.show(String(localized: "Cannot Install"), message: message)
            return
        }
        let alert = AlertViewController(title: "Cannot Install", message: message) { context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: "Open With…", attribute: .accent) {
                context.dispose { self.share([path]) }
            }
        }
        presenter.present(alert, animated: true)
    }

    func showProperties(_ path: String) {
        Task {
            do {
                let details = try await session.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
                guard let presenter = activePresenter else { return }
                presenter.presentAsSheet(UINavigationController(rootViewController: PropertiesViewController(details: details, link: session.link)))
            } catch { report(error) }
        }
    }

    func delete(_ paths: [String], permanently: Bool = false) {
        guard !paths.isEmpty else { return }
        // Inside the trash every delete is final, whichever control asked:
        // trashing a trashed item would only move it within the trash.
        if AppPreferences.shared.usesTrash, !permanently, !paths.allSatisfy(Self.isInTrash) {
            startDelete(paths, useTrash: true)
        } else {
            guard let presenter = activePresenter else { return }
            PermanentDeleteConfirmation.present(
                from: presenter, title: String(localized: "Delete Permanently?"),
                message: String(localized: "\(paths.count) items will be deleted and cannot be recovered.")
            ) { self.startDelete(paths) }
        }
    }

    func promptOverriddenDelete(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        guard let presenter = activePresenter else { return }
        PermanentDeleteConfirmation.present(
            from: presenter, title: String(localized: "Override Protection?"),
            message: String(localized: "The device needs this item to start up. Deleting it cannot be undone, and the device may need to be restored."),
            confirmTitle: String(localized: "Delete Anyway")
        ) { self.startDelete(paths, overrideGuard: true) }
    }

    private func startDelete(_ paths: [String], useTrash: Bool = false, overrideGuard: Bool = false) {
        presenter?.setEditing(false, animated: true)
        Task {
            let kind: OperationCenter.Kind = useTrash ? .trash : .delete
            let description = OperationCenter.describe(paths, destination: nil)
            let progress = AlertProgressIndicatorViewController(title: kind.runningTitle, message: description)
            let reveal = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000))
                } catch { return }
                guard !Task.isCancelled, let presenter = activePresenter else { return }
                // Wait for presentation to finish before a job that completes
                // during the animation asks this same alert to dismiss.
                await withCheckedContinuation { continuation in
                    presenter.present(progress, animated: true) { continuation.resume() }
                }
            }
            let result: Result<FilaFailure, Error>
            do {
                let outcome = try await withSourceLocked {
                    if useTrash { return try await session.operations.trash(paths, feedback: .successOnly) }
                    return try await session.operations.awaitJob(
                        JobRequest(kind: .delete, sources: paths, useTrash: useTrash, overrideGuard: overrideGuard),
                        kind: kind,
                        subtitle: description,
                        feedback: .successOnly
                    )
                }
                result = .success(outcome)
            } catch { result = .failure(error) }

            reveal.cancel()
            await reveal.value
            let complete = {
                switch result {
                case let .success(outcome):
                    if outcome.code == .success { self.didRemove() }
                    else if outcome.code != .cancelled {
                        self.reportDeleteFailure(outcome, paths: paths, useTrash: useTrash)
                    }
                case let .failure(failure as FilaFailure):
                    self.reportDeleteFailure(failure, paths: paths, useTrash: useTrash)
                case let .failure(error): self.report(error)
                }
            }
            // Background work may outlive this screen or a newer sheet. Only
            // close the alert this operation presented, then report its result.
            if progress.presentingViewController?.presentedViewController === progress,
               progress.presentedViewController == nil, !progress.isBeingDismissed {
                progress.dismiss(animated: true, completion: complete)
            } else {
                // A toast can present Transfers above this alert. Keep that
                // sheet and leave a truthful result underneath it.
                if progress.presentedViewController != nil {
                    switch result {
                    case let .success(outcome):
                        switch outcome.code {
                        case .success: progress.progressContext.purpose(message: kind.completionTitle)
                        case .cancelled: progress.progressContext.purpose(message: String(localized: "Cancelled"))
                        default: progress.progressContext.purpose(message: FailureText.title(for: outcome))
                        }
                    case let .failure(error):
                        progress.progressContext.purpose(
                            message: error is CancellationError || (error as? FilaFailure)?.code == .cancelled
                                ? String(localized: "Cancelled") : String(localized: "Operation Failed")
                        )
                    }
                }
                complete()
            }
        }
    }

    private func reportDeleteFailure(_ failure: FilaFailure, paths: [String], useTrash: Bool) {
        guard failure.code != .success, failure.code != .cancelled else { return }
        guard useTrash, failure.systemError == EXDEV || failure.systemError == EROFS,
              let presenter = activePresenter else { return report(failure) }
        PermanentDeleteConfirmation.present(
            from: presenter, title: String(localized: "Cannot Move to Trash"),
            message: String(localized: "The trash is on another volume or cannot be written to. Permanently delete the selected items still at their original paths? Items already in the trash will stay there. This cannot be undone.")
        ) { self.deleteRemainingItems(at: paths) }
    }

    /// A new, explicitly confirmed deletion of the items currently at these
    /// paths. Missing names are skipped, never treated as proof of a trash move.
    private func deleteRemainingItems(at paths: [String]) {
        Task {
            do {
                var remaining: [String] = []
                for path in paths {
                    do {
                        _ = try await session.perform { try await $0.details(of: path) }
                        remaining.append(path)
                    } catch let failure as FilaFailure where failure.code == .notFound || failure.systemError == ENOENT {
                        continue
                    }
                }
                guard !remaining.isEmpty else { didRemove(); return }
                startDelete(remaining)
            } catch { report(error) }
        }
    }

    func promptRename(_ path: String) {
        guard let presenter = activePresenter else { return }
        let source = URL(fileURLWithPath: path)
        let alert = AlertInputViewController(
            title: "Rename",
            message: "Enter a new name. The item stays in the same folder.",
            placeholder: .noPlaceholder,
            text: source.lastPathComponent,
            doneButtonText: "Rename"
        ) { name in
            guard name != source.lastPathComponent else { return }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                self.report(FilaFailure(code: .invalidRequest, systemError: EINVAL, path: name))
                return
            }
            self.rename(path, to: source.deletingLastPathComponent().appendingPathComponent(name).path, replacingExisting: false)
        }
        presenter.present(alert, animated: true)
    }

    private func rename(_ source: String, to destination: String, replacingExisting: Bool) {
        Task {
            do {
                try await withSourceLocked {
                    try await session.perform { try await $0.rename(source, to: destination, exclusive: !replacingExisting) }
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
        let base = paths.count == 1 ? URL(fileURLWithPath: paths[0]).deletingPathExtension().lastPathComponent : URL(fileURLWithPath: directory).lastPathComponent
        CompressViewController.present(
            from: presenter, suggestedName: base.isEmpty ? "Archive" : base, directory: directory, itemCount: paths.count, link: session.link
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
                let destination = try await freeArchivePath(base: stem, format: options.format, in: directory)
                let request = JobRequest(kind: .compress, sources: paths, destination: destination, archive: options)
                let identifier = try await center.startJob(
                    request,
                    kind: .compress,
                    title: OperationCenter.Kind.compress.runningTitle,
                    subtitle: OperationCenter.describe(paths, destination: directory)
                )
                guard let operation = center.operation(forJob: identifier), let presenter = activePresenter else { return }
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
    private func withSourceLocked<T>(_ body: () async throws -> T) async rethrows -> T {
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

    private var activePresenter: UIViewController? {
        guard let presenter, presenter.viewIfLoaded?.window != nil,
              presenter.navigationController?.topViewController === presenter else { return nil }
        var ancestor: UIViewController? = presenter
        while let controller = ancestor {
            guard controller.presentedViewController == nil, !controller.isBeingDismissed else { return nil }
            ancestor = controller.parent
        }
        return presenter
    }

    private func confirmDestruction(title: String, message: String, confirm: String, handler: @escaping () -> Void) {
        guard let presenter = activePresenter else { return }
        let alert = AlertViewController(title: title, message: message) { context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: confirm, attribute: .accent) {
                context.dispose { handler() }
            }
        }
        presenter.present(alert, animated: true)
    }

    private func report(_ error: Error) {
        if let failure = error as? FilaFailure, failure.code == .success || failure.code == .cancelled { return }
        if error is CancellationError { return }
        guard let presenter = activePresenter else {
            FeedbackAlert.show(String(localized: "Operation Failed"), message: FailureMessage.text(for: error))
            return
        }
        if let failure = error as? FilaFailure { presenter.report(failure); return }
        let alert = AlertViewController(
            title: "Operation Failed",
            message: FailureMessage.text(for: error)
        ) { context in
            context.allowSimpleDispose()
            context.addAction(title: "OK", attribute: .accent) {
                context.dispose()
            }
        }
        presenter.present(alert, animated: true)
    }

    private func freeArchivePath(base: String, format: ArchiveFormat, in directory: String) async throws -> String {
        for index in 1 ... Int.max {
            try Task.checkCancellation()
            let name = index == 1 ? "\(base).\(format.filenameExtension)" : "\(base) \(index).\(format.filenameExtension)"
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
