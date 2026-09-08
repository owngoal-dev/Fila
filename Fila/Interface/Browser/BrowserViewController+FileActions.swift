import AlertController
import FilaClient
import FilaProtocol
import UIKit

/// Browser navigation, selection, and transfer UI. File actions are shared
/// with previews and editors through `FileActions`.
///
/// None of this decides whether an operation is allowed — `FilaGuard` runs in
/// the daemon and is the only thing that does. A greyed item here is a courtesy
/// to save a round trip, nothing more.
extension BrowserViewController {
    var deleteTitle: String {
        FileActions.deleteTitle
    }

    private var fileActions: FileActions {
        FileActions(presenter: self, directory: directory)
    }

    // MARK: - Menus

    func contextMenu(for node: FileNode) -> UIMenu {
        let path = path(of: node)
        var file: [UIMenuElement] = []
        // Only folders: a tab is somewhere to be, and "open this PNG in a new
        // tab" has no answer that is not a viewer with no way back. Not in the
        // trash, where `FileActions` hands back Put Back and little else.
        if node.isNavigable, !isTrash {
            file.append(UIAction(
                title: String(localized: "Open in New Tab"),
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                self?.shell?.openInNewTab(path)
            })
        }
        // A link's row now draws its target's icon, so "where does this
        // actually go" is the question the row raises and this is the answer to
        // it. Disabled rather than absent when the link dangles: the item
        // missing would read as the menu not having it, and an alert after the
        // tap makes a person ask a question they could have been spared.
        if node.kind == .symbolicLink, !isTrash, let link = node.link {
            let broken = link.isBroken
            file.append(UIAction(
                title: String(localized: "Show Original"),
                subtitle: broken ? String(localized: "The original item no longer exists.") : nil,
                image: UIImage(systemName: "arrowshape.turn.up.right.circle"),
                attributes: broken ? .disabled : []
            ) { [weak self] _ in
                guard let self, let original = originalPath(of: node) else { return }
                // A directory is somewhere to be, a file is something to be
                // shown in its folder — which is `fila://open` and
                // `fila://reveal`, so it goes through them rather than past
                // them. Both re-root the tab: see `open(directory:)` for why
                // going anywhere that is not a child of this folder is a jump.
                shell?.follow(link.resolvedKind == .directory ? .directory(original) : .reveal(original))
            })
        }

        return UIMenu(
            title: node.name,
            children: fileActions.menuElements(
                for: path,
                node: node,
                additional: file,
                preview: { [weak self] in self?.open(node) }
            )
        )
    }

    /// Takes the trash's place in the folder menu, where New would be. Not
    /// while the listing still streams: emptying what has arrived so far
    /// would leave the rest with a confirmation that named the wrong count.
    func emptyTrashAction() -> UIAction {
        UIAction(
            title: String(localized: "Empty Trash"),
            image: UIImage(systemName: "trash"),
            attributes: entries.isEmpty || isListing ? [.destructive, .disabled] : .destructive
        ) { [weak self] _ in
            guard let self else { return }
            // Every entry, hidden ones included: the trash is emptied, not the
            // view of it. The permanent-delete confirmation names the count.
            delete(entries.map(path(of:)), permanently: true)
        }
    }

    /// Put Back is not a job, so nothing tells this list to reload but the
    /// action itself.
    func putBack(_ paths: [String]) {
        FileActions(presenter: self, directory: directory, didRemove: { [weak self] in self?.reload() }).putBack(paths)
    }

    /// Where a symlink actually points, as a path something can be asked for.
    ///
    /// A target is whatever string `readlink(2)` gave back: absolute, or
    /// relative to the directory the link is in — `/etc -> private/etc` is the
    /// second kind and is the common one. The `..` in a relative target is
    /// folded away by `standardizedFileURL`, which is lexical and touches no
    /// file; resolving it for real is `realpath(3)` in the daemon, which runs
    /// on whatever finally arrives there anyway.
    func originalPath(of node: FileNode) -> String? {
        guard let target = node.link?.target, !target.isEmpty else { return nil }
        let joined = target.hasPrefix("/") ? target : (directory as NSString).appendingPathComponent(target)
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }

    func browserMenuElements(folderAction: UIMenuElement, selectAction: UIAction) -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        let layouts = BrowserLayout.allCases.map { layout in
            UIAction(
                title: layout == .grid ? String(localized: "Grid") : String(localized: "List"),
                image: UIImage(systemName: layout == .grid ? "square.grid.2x2" : "list.bullet"),
                state: preferences.layout(for: directory) == layout ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                AppPreferences.shared.setLayout(layout, for: directory)
                viewPreferenceChanged(relayout: true)
            }
        }
        // These are ordinary submenus on every OS: keep the home menu's
        // creation, display preferences, and navigation groups in this order.
        let hidden = [true, false].map { showsHidden in
            UIAction(
                title: showsHidden ? String(localized: "Show") : String(localized: "Hide"),
                state: preferences.showsHidden == showsHidden ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                AppPreferences.shared.showsHidden = showsHidden
                viewPreferenceChanged(relayout: false)
            }
        }
        let view = UIMenu(options: .displayInline, children: [
            UIMenu(
                title: String(localized: "View"),
                image: UIImage(systemName: "square.grid.2x2"),
                options: .singleSelection,
                children: layouts
            ),
            UIMenu(
                title: String(localized: "Hidden Files"),
                image: UIImage(systemName: "eye.slash"),
                options: .singleSelection,
                children: hidden
            ),
            UIMenu(
                title: String(localized: "Sort By"),
                image: UIImage(systemName: "arrow.up.arrow.down"),
                children: sortMenuElements()
            ),
        ])
        let more: [UIMenuElement] = [
            selectAction,
            UIAction(
                title: preferences.isFavorite(directory)
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites"),
                image: UIImage(systemName: preferences.isFavorite(directory) ? "star.slash" : "star")
            ) { [weak self] _ in
                guard let self else { return }
                AppPreferences.shared.toggleFavorite(directory)
            },
            UIAction(
                title: String(localized: "Open in New Tab"),
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                guard let self else { return }
                shell?.openInNewTab(directory)
            },
        ]
        // The browser's Go menu changes the current location; More acts on
        // the current folder. Keep these separate from the overview's new-tab menu.
        let navigation: [UIMenuElement] = [
            UIMenu(
                title: String(localized: "Go"),
                image: UIImage(systemName: "arrow.right.circle"),
                children: goMenuElements()
            ),
            UIMenu(title: String(localized: "More"), image: UIImage(systemName: "ellipsis.circle"), children: more),
        ]
        return FilaMenu.groups([folderAction]) + [view] + FilaMenu.groups(navigation)
    }

    private func goMenuElements() -> [UIMenuElement] {
        FilaMenu.destinations(includesFiles: true) { [weak self] in
            self?.promptGoToPath()
        } open: { [weak self] path, isFile in
            if isFile {
                self?.shell?.follow(.view(path))
            } else {
                self?.open(directory: path)
            }
        }
    }

    func sortMenuElements() -> [UIMenuElement] {
        let preferences = AppPreferences.shared
        let titles: [FileSortKey: String] = [
            .name: String(localized: "Name"),
            .date: String(localized: "Date"),
            .size: String(localized: "Size"),
            .kind: String(localized: "Kind"),
        ]
        let keys = FileSortKey.allCases.map { key in
            UIAction(
                title: titles[key] ?? key.rawValue,
                state: preferences.sortKey == key ? .on : .off
            ) { [weak self] _ in
                let preferences = AppPreferences.shared
                preferences.sortKey = key
                self?.viewPreferenceChanged(relayout: false)
            }
        }
        let directions = [true, false].map { ascending in
            UIAction(
                title: ascending ? String(localized: "Ascending") : String(localized: "Descending"),
                state: preferences.isAscending == ascending ? .on : .off
            ) { [weak self] _ in
                AppPreferences.shared.isAscending = ascending
                self?.viewPreferenceChanged(relayout: false)
            }
        }
        return [
            UIMenu(options: [.displayInline, .singleSelection], children: keys),
            UIMenu(options: [.displayInline, .singleSelection], children: directions),
        ]
    }

    func newMenu() -> UIMenu {
        UIMenu(title: String(localized: "New"), image: UIImage(systemName: "plus"), children: FilaMenu.groups([
            UIAction(
                title: String(localized: "Folder"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in
                self?.promptCreate(.directory)
            },
            UIAction(
                title: String(localized: "Text File"),
                image: UIImage(systemName: "doc.badge.plus")
            ) { [weak self] _ in
                self?.promptCreate(.emptyFile)
            },
            UIAction(
                title: String(localized: "Symbolic Link"),
                image: UIImage(systemName: "arrowshape.turn.up.right")
            ) { [weak self] _ in
                self?.promptCreateLink()
            },
        ], [
            UIAction(
                title: String(localized: "Import Photos…"),
                image: UIImage(systemName: "photo.on.rectangle")
            ) { [weak self] _ in
                self?.importPhotos()
            },
            UIAction(
                title: String(localized: "Import Files…"),
                image: UIImage(systemName: "square.and.arrow.down")
            ) { [weak self] _ in
                self?.importDocuments()
            },
            UIAction(
                title: String(localized: "Download from URL…"),
                image: UIImage(systemName: "arrow.down.circle")
            ) { [weak self] _ in
                self?.promptDownload()
            },
        ]))
    }

    // MARK: - Operations

    func takeSelection(cut: Bool) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        FileClipboard.shared.take(paths, cut: cut)
        setEditing(false, animated: true)
    }

    func paste() {
        // Nothing is created in the trash, by any route: a pasted item would
        // sit there with no origin to put it back to.
        guard !isTrash, let paste = FileClipboard.shared.beginPaste() else { return }
        recordDirectoryUse()
        let request = JobRequest(
            kind: paste.isCut ? .move : .copy,
            sources: paste.paths,
            destination: directory
        )
        transfer(request, paste: paste)
    }

    func delete(_ paths: [String], permanently: Bool = false) {
        fileActions.delete(paths, permanently: permanently)
    }

    func compress(_ paths: [String]) {
        fileActions.promptCompress(paths)
    }

    func presentSearch() {
        recordDirectoryUse()
        navigationController?.pushViewController(SearchViewController(root: directory, scope: .folder), animated: true)
    }

    // MARK: - Prompts

    func promptCreate(_ template: NodeTemplate) {
        guard !isTrash else { return }
        recordDirectoryUse()
        let title = template == .directory
            ? String.LocalizationValue("New Folder")
            : String.LocalizationValue("New Text File")
        let initial = template == .directory ? "" : String(localized: "Untitled.txt")
        prompt(
            title: title,
            message: String.LocalizationValue("Enter a name for the new item in this folder."),
            initial: initial,
            confirm: String.LocalizationValue("Create")
        ) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let path = directory == "/" ? "/" + name : directory + "/" + name
            run { try await $0.create(template, at: path) }
        }
    }

    /// The target is picked, not typed: the folder panel in its file-picking
    /// mode, then one name prompt already filled with the target's own name.
    func promptCreateLink() {
        let picker = SaveDestinationViewController(
            directory: URL(fileURLWithPath: directory, isDirectory: true),
            picksFiles: true,
            link: session.link
        ) { [weak self] target in
            guard let self else { return }
            prompt(
                title: String.LocalizationValue("New Symbolic Link"),
                message: String.LocalizationValue("Enter a name for the link to the item you chose."),
                initial: target.lastPathComponent,
                confirm: String.LocalizationValue("Create")
            ) { [weak self] name in
                guard let self, !name.isEmpty else { return }
                let path = directory == "/" ? "/" + name : directory + "/" + name
                run { try await $0.create(.symbolicLink(target: target.path), at: path) }
            }
        }
        presentAsSheet(UINavigationController(rootViewController: picker))
    }

    /// The address goes to `OperationCenter`, which gives it a transfers row
    /// with a progress bar and a stop button like any other transfer. Only
    /// `http` and `https` — a `file://` URL would be `URLSession` reading a path
    /// as `mobile`, which is the one way of reaching the filesystem this app
    /// does not have.
    func promptDownload() {
        prompt(
            title: String.LocalizationValue("Download from URL"),
            message: String.LocalizationValue("Enter an http or https URL. The file is saved in this folder."),
            initial: "https://",
            confirm: String.LocalizationValue("Download")
        ) { [weak self] text in
            guard let self,
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { return }
            let center = session.operations
            let operationID = center.download(url, into: directory)
            // Use the extraction card's delayed presentation and cancellation;
            // the returned identity also keeps simultaneous downloads separate.
            OperationCoverViewController.present(for: operationID, from: self, center: center)
        }
    }

    func promptGoToPath() {
        prompt(
            title: String.LocalizationValue("Go to Path"),
            message: String.LocalizationValue("Enter an absolute path, starting with a slash."),
            initial: directory,
            confirm: String.LocalizationValue("Go")
        ) { [weak self] path in
            guard let self, path.hasPrefix("/") else { return }
            open(directory: path)
        }
    }

    func promptDrop(sources: [String], target: String) {
        let alert = AlertViewController(
            title: (target as NSString).lastPathComponent,
            message: String(localized: "Copy keeps the originals. Move takes them out of their current folder.")
        ) { [weak self] context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Copy Here")) {
                context.dispose {
                    self?.transfer(JobRequest(kind: .copy, sources: sources, destination: target))
                }
            }
            context.addAction(title: String.LocalizationValue("Move Here"), attribute: .accent) {
                context.dispose {
                    self?.transfer(JobRequest(kind: .move, sources: sources, destination: target))
                }
            }
        }
        alert.shouldDismissWhenTappedAround = true
        present(alert, animated: true)
    }

    private func prompt(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        initial: String,
        confirm: String.LocalizationValue,
        handler: @escaping (String) -> Void
    ) {
        let alert = AlertInputViewController(
            title: title,
            message: message,
            placeholder: .noPlaceholder,
            text: initial,
            doneButtonText: confirm
        ) { name in
            handler(name)
        }
        present(alert, animated: true)
    }

    // MARK: - Plumbing

    private func transfer(_ request: JobRequest, paste: FileClipboard.Paste? = nil) {
        Task { [self] in
            var outcome: FilaFailure
            do {
                outcome = try await performTransfer(request)
            } catch let failure as FilaFailure {
                outcome = failure
            } catch {
                outcome = FilaFailure(code: .operationFailed)
            }

            if let paste {
                // The result covers the batch, not individual roots. A failed
                // move retains the selection; disappearance alone cannot prove
                // which items this operation moved.
                FileClipboard.shared.finishPaste(paste, succeeded: outcome.code == .success)
            }
            if outcome.code != .success, outcome.code != .cancelled {
                var message = FailureMessage.text(for: outcome)
                if let path = outcome.path {
                    message += "\n\n" + path
                }
                if paste != nil {
                    message += "\n\n" + String(localized: "Check the source and destination folders before trying again. Some items may already have been transferred.")
                }
                FeedbackAlert.show(
                    request.kind == .move
                        ? String(localized: "Unable to Move Items")
                        : String(localized: "Unable to Copy Items"),
                    message: message
                )
            }
        }
    }

    /// Importers keep their staged sources alive through the actual job result,
    /// including a replacement retry, before removing their workspace.
    func performTransfer(_ request: JobRequest) async throws -> FilaFailure {
        let kind: OperationCenter.Kind = request.kind == .move ? .move : .copy
        let subtitle = OperationCenter.describe(request.sources, destination: request.destination)
        let outcome = try await session.operations.awaitJob(request, kind: kind, subtitle: subtitle, feedback: .silent)
        guard outcome.systemError == EEXIST, !request.overwrite else { return outcome }
        guard await confirmTransferReplacement() else { return FilaFailure(code: .cancelled) }
        var replacement = request
        replacement.overwrite = true
        return try await session.operations.awaitJob(replacement, kind: kind, subtitle: subtitle, feedback: .silent)
    }

    private func confirmTransferReplacement() async -> Bool {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self else { return false }
        var presenter: UIViewController? = self
        while let controller = presenter {
            guard controller.presentedViewController == nil, !controller.isBeingDismissed else { return false }
            presenter = controller.parent
        }
        return await withCheckedContinuation { continuation in
            let alert = AlertViewController(
                title: String.LocalizationValue("Replace Existing Items?"),
                message: String.LocalizationValue("Items with the same names will be replaced, not moved to the trash. This cannot be undone. Non-empty folders cannot be replaced.")
            ) { context in
                context.addAction(title: String.LocalizationValue("Cancel")) {
                    context.dispose { continuation.resume(returning: false) }
                }
                context.addAction(title: String.LocalizationValue("Replace"), attribute: .accent) {
                    context.dispose { continuation.resume(returning: true) }
                }
            }
            present(alert, animated: true)
        }
    }

    private func run(_ body: @escaping (DaemonLink) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.perform(body)
            } catch let failure as FilaFailure {
                self.report(failure)
            } catch {}
            reload()
        }
    }
}
