import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import UIKit

/// Browser navigation, selection, and transfer UI. File actions are shared
/// with previews and editors through `FileActions`.
///
/// None of this decides whether an operation is allowed — `FilaGuard` runs in
/// the daemon and is the only thing that does. A greyed item here is a courtesy
/// to save a round trip, nothing more.
extension FileBrowserViewController {
    var deleteTitle: String {
        FileActions.deleteTitle
    }

    private var fileActions: FileActions {
        FileActions(presenter: self, directory: directory, removals: self)
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
                image: UIImage(systemName: "plus.square.on.square"),
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
                attributes: broken ? .disabled : [],
            ) { [weak self] _ in
                guard let self, let original = originalPath(of: node) else { return }
                // A directory is somewhere to be, a file is something to be
                // shown in its folder — the router's `.directory` and
                // `.reveal`, where `fila://` links land, so it goes through
                // them rather than past them. The kind is already known, so
                // there is no lookup. Both re-root the tab: see
                // `open(directory:)` for why going anywhere that is not a
                // child of this folder is a jump.
                shell?.follow(link.resolvedKind == .directory ? .directory(original) : .reveal(original))
            })
        }

        return UIMenu(
            title: node.name,
            children: fileActions.menuElements(
                for: path,
                node: node,
                additional: file,
                select: isEditing ? nil : { [weak self] in self?.select(node) },
                preview: { [weak self] in self?.preview(node) },
            ),
        )
    }

    /// Takes the trash's place in the folder menu, where New would be. Not
    /// while the listing still streams: emptying what has arrived so far
    /// would leave the rest with a confirmation that named the wrong count.
    func emptyTrashAction() -> UIAction {
        UIAction(
            title: String(localized: "Empty Trash"),
            image: UIImage(systemName: "trash"),
            attributes: items.isEmpty || isLoading ? [.destructive, .disabled] : .destructive,
        ) { [weak self] _ in
            guard let self else { return }
            // Every entry, hidden ones included: the trash is emptied, not the
            // view of it. The permanent-delete confirmation names the count.
            delete(items.map(path(of:)), permanently: true)
        }
    }

    /// Put Back is not a job, so nothing tells this list to reload but the
    /// action itself — which `removalDidEnd` does.
    func putBack(_ paths: [String]) {
        fileActions.putBack(paths)
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

    /// The ellipsis menu, top to bottom: what acts on this folder, then its
    /// display as two switches, then creating something, then where to go.
    ///
    /// "More" used to hold the row actions one level down, and View and Hidden
    /// Files were two-option submenus of a two-option kind: a menu that is
    /// opened for a folder should say what can be done with it in its first
    /// group, and a choice of two belongs in one switch, not a submenu.
    func browserMenuElements(folderAction: UIMenuElement, selectAction: UIAction) -> [UIMenuElement] {
        let actions: [UIMenuElement] = [
            selectAction,
            favoriteToggleAction(keepsMenuOpen: true),
            UIAction(
                title: String(localized: "Open in New Tab"),
                image: UIImage(systemName: "plus.square.on.square"),
            ) { [weak self] _ in
                guard let self else { return }
                shell?.openInNewTab(directory)
            },
        ]
        let display: [UIMenuElement] = [
            layoutToggleAction(),
            hiddenFilesToggleAction(),
            UIMenu(
                title: String(localized: "Sort By"),
                image: UIImage(systemName: "arrow.up.arrow.down"),
                children: sortMenuElements(),
            ),
        ]
        let navigation: [UIMenuElement] = [
            UIMenu(
                title: String(localized: "Go"),
                image: UIImage(systemName: "arrow.right.circle"),
                children: goMenuElements(),
            ),
            settingsMenuElement,
        ]
        return FilaMenu.groups(actions, display, [folderAction], navigation)
    }

    /// The layout as one switch rather than a submenu of two rows. The label
    /// names the mode the check mark describes and does not change under the
    /// finger: tapping flips the mode with the menu still open, so the mark is
    /// what moves.
    private func layoutToggleAction() -> UIAction {
        let isList = session.layout(for: directory) == .list
        return UIAction(
            title: String(localized: "Show as List"),
            image: UIImage(systemName: "list.bullet"),
            attributes: Self.staysOpenWhileToggling,
            state: isList ? .on : .off,
        ) { [weak self] _ in
            guard let self else { return }
            session.setLayout(isList ? .grid : .list, for: directory)
            viewPreferenceChanged(relayout: true)
            refreshMoreMenu()
        }
    }

    /// The same shape for hidden files: one switch, wording first, mark on the
    /// state — it used to be Show/Hide inside a submenu called Hidden Files.
    private func hiddenFilesToggleAction() -> UIAction {
        let shows = session.showsHidden
        return UIAction(
            title: String(localized: "Show Hidden Files"),
            image: UIImage(systemName: "eye"),
            attributes: Self.staysOpenWhileToggling,
            state: shows ? .on : .off,
        ) { [weak self] _ in
            guard let self else { return }
            session.setShowsHidden(!shows)
            viewPreferenceChanged(relayout: false)
            refreshMoreMenu()
        }
    }

    /// A switch that closed the menu would make a person open it again to see
    /// what it did. iOS 16 knows the attribute; before it, a tap still closes
    /// the menu and the marks are read on the next opening.
    private static var staysOpenWhileToggling: UIMenuElement.Attributes {
        if #available(iOS 16.0, *) {
            return [.keepsMenuPresented]
        }
        return []
    }

    /// This folder into or out of the favourites, worded for its state when
    /// the menu is built.
    ///
    /// `keepsMenuOpen` is for the ellipsis, a bar button item: handing its item
    /// a rebuilt menu repaints the presented menu where it stands, so the row
    /// flips under the finger. The breadcrumb's current crumb is a `UIButton`,
    /// and its menu is presented again when it is handed a new one — there the
    /// row would blink closed and open, so that menu closes as it always has.
    private func favoriteToggleAction(keepsMenuOpen: Bool = false) -> UIAction {
        let favorite = session.isFavorite(directory)
        return UIAction(
            title: favorite
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites"),
            image: UIImage(systemName: favorite ? "star.slash" : "star"),
            attributes: keepsMenuOpen ? Self.staysOpenWhileToggling : [],
        ) { [weak self] _ in
            guard let self else { return }
            session.toggleFavorite(directory)
            if keepsMenuOpen {
                refreshMoreMenu()
            }
        }
    }

    /// A tap on the current breadcrumb: this folder in or out of the
    /// favourites, then the favourites to jump to. The toggle means the menu
    /// is never empty, and it is what the star beside the crumb promises.
    func makeCurrentCrumbMenu() -> UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self.map { [$0.favoriteToggleAction()] } ?? [])
                },
            ]),
            UIMenu(options: .displayInline, children: [
                FilaMenu.favoriteItems { [weak self] path in self?.open(directory: path) },
            ]),
        ])
    }

    /// A long press on the current breadcrumb: the rows of Go › Places,
    /// built when the menu opens so the capabilities are current.
    /// No title: the menu is the places, and a heading over them says nothing
    /// the rows do not.
    func makeCurrentCrumbPlacesMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(FilaMenu.placeActions(
                    open: { [weak self] path in self?.open(directory: path) },
                    openLocation: { [weak self] location in self?.openLocation(location) },
                ))
            },
        ])
    }

    private func goMenuElements() -> [UIMenuElement] {
        FilaMenu.destinations { [weak self] in
            self?.promptGoToPath()
        } open: { [weak self] path in
            self?.open(directory: path)
        } openLocation: { [weak self] location in
            self?.openLocation(location)
        }
    }

    /// A catalogue or a share replaces the tab's page, as its sidebar row does.
    private func openLocation(_ location: BackendLocation) {
        guard let screen = SidebarLocation.screen(for: location) else { return }
        shell?.replace(screen)
    }

    func sortMenuElements() -> [UIMenuElement] {
        let titles: [FileSortKey: String] = [
            .name: String(localized: "Name"),
            .date: String(localized: "Date"),
            .size: String(localized: "Size"),
            .kind: String(localized: "Kind"),
        ]
        let keys = FileSortKey.allCases.map { key in
            UIAction(
                title: titles[key] ?? key.rawValue,
                state: session.sortKey == key ? .on : .off,
            ) { [weak self] _ in
                guard let self else { return }
                session.setSort(key: key, ascending: session.sortAscending)
                viewPreferenceChanged(relayout: false)
            }
        }
        let directions = [true, false].map { ascending in
            UIAction(
                title: ascending ? String(localized: "Ascending") : String(localized: "Descending"),
                state: session.sortAscending == ascending ? .on : .off,
            ) { [weak self] _ in
                guard let self else { return }
                session.setSort(key: session.sortKey, ascending: ascending)
                viewPreferenceChanged(relayout: false)
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
                image: UIImage(systemName: "folder.badge.plus"),
            ) { [weak self] _ in
                self?.promptCreate(.directory)
            },
            UIAction(
                title: String(localized: "Text File"),
                image: UIImage(systemName: "doc.badge.plus"),
            ) { [weak self] _ in
                self?.promptCreate(.emptyFile)
            },
            UIAction(
                title: String(localized: "Symbolic Link"),
                image: UIImage(systemName: "arrowshape.turn.up.right"),
            ) { [weak self] _ in
                self?.promptCreateLink()
            },
        ], [
            UIAction(
                title: String(localized: "Import Photos…"),
                image: UIImage(systemName: "photo.on.rectangle"),
            ) { [weak self] _ in
                self?.importPhotos()
            },
            UIAction(
                title: String(localized: "Import Files…"),
                image: UIImage(systemName: "square.and.arrow.down"),
            ) { [weak self] _ in
                self?.importDocuments()
            },
            UIAction(
                title: String(localized: "Download from URL…"),
                image: UIImage(systemName: "arrow.down.circle"),
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

    func paste(mode: TransferMode) {
        // Nothing is created in the trash, by any route: a pasted item would
        // sit there with no origin to put it back to.
        guard !isTrash, !FileClipboard.shared.isEmpty else { return }
        recordDirectoryUse()
        ClipboardPaste.paste(into: .local(directory), mode: mode, from: self)
    }

    func delete(_ paths: [String], permanently: Bool = false) {
        fileActions.delete(paths, permanently: permanently)
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
            placeholder: template == .directory
                ? String.LocalizationValue("Folder name")
                : String.LocalizationValue("File name"),
            initial: initial,
            confirm: String.LocalizationValue("Create"),
        ) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            guard FileActions.isItemName(name) else { return refuseName(name) }
            let path = path(ofName: name)
            run { try await $0.create(template, at: path) }
        }
    }

    /// The same refusal Rename gives: a typed slash or `..` would create the
    /// item outside the folder the prompt promised.
    private func refuseName(_ name: String) {
        FileActions.refuseName(name)
    }

    /// The target is picked, not typed: the folder panel in its file-picking
    /// mode, then one name prompt already filled with the target's own name.
    func promptCreateLink() {
        let picker = SaveDestinationViewController(
            picksFiles: true,
            link: session.link,
        ) { [weak self] target in
            guard let self else { return }
            prompt(
                title: String.LocalizationValue("New Symbolic Link"),
                message: String.LocalizationValue("Enter a name for the link to the item you chose."),
                placeholder: String.LocalizationValue("Link name"),
                initial: target.lastPathComponent,
                confirm: String.LocalizationValue("Create"),
            ) { [weak self] name in
                guard let self, !name.isEmpty else { return }
                guard FileActions.isItemName(name) else { return refuseName(name) }
                let path = path(ofName: name)
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
            placeholder: String.LocalizationValue("URL"),
            initial: "https://",
            confirm: String.LocalizationValue("Download"),
        ) { [weak self] text in
            guard let self,
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { return }
            let center = session.operations
            let operationID = center.download(url, into: directory)
            // Use the extraction card's delayed presentation and cancellation;
            // the returned identity also keeps simultaneous downloads separate.
            OperationCoverViewController.present(.operation(operationID, in: center), from: self)
        }
    }

    func promptGoToPath() {
        prompt(
            title: String.LocalizationValue("Go to Path"),
            message: String.LocalizationValue("Enter a path starting with a slash."),
            placeholder: String.LocalizationValue("Absolute path"),
            initial: directory,
            confirm: String.LocalizationValue("Go"),
        ) { [weak self] path in
            // Canonical as a `fila://` link's path is: a trailing slash or a
            // `.` left in would name every child so that it never reads as a
            // child, and each tap below would re-root the tab.
            guard let self, let path = FilaLink.canonical(path) else { return }
            open(directory: path)
        }
    }

    private func prompt(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        placeholder: String.LocalizationValue,
        initial: String,
        confirm: String.LocalizationValue,
        handler: @escaping (String) -> Void,
    ) {
        let alert = AlertInputViewController(
            title: title,
            message: message,
            placeholder: placeholder,
            text: initial,
            doneButtonText: confirm,
            onConfirm: handler,
        ).typingLiterally()
        present(alert, animated: true)
    }

    // MARK: - Plumbing

    private func run(_ body: @escaping (any LocalFileAccess) async throws -> Void) {
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
