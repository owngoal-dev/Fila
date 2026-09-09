import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import SnapKit
import UIKit

/// What Copy and Move are actually holding.
///
/// Without this screen the clipboard is invisible: Paste is enabled or it is
/// greyed out, and that is the whole of the feedback. Worse, the thing it holds
/// is a list of *locations*, and a location is a promise that breaks quietly —
/// the file moves, or another tab deletes it, and the only symptom is a paste
/// that fails later with an `errno` and no explanation of which of the six
/// items was the problem.
///
/// So every entry is checked against its backend when the screen appears, and
/// an entry that no longer resolves says so here, in the one place where the
/// user can do something about it: remove it, or clear the lot. A missing entry
/// is never dropped silently — a clipboard that quietly shrinks is worse than
/// one that is wrong, because the user has no way to notice either.
///
/// The browser presents this in a navigation controller from its pending bar or menu.
final class ClipboardViewController: TabContentViewController {
    /// Where an entry goes when it is tapped. Set by whoever presents this: the
    /// browser owns navigation and this screen knows nothing about it.
    var onReveal: ((FileLocation) -> Void)?

    /// What the backend says about one held location, right now.
    private enum Status {
        case checking
        case present(FileEntry)
        /// The location resolves to nothing. The promise is broken.
        case missing
        /// It is there, or it may be — the backend refused to say. Reported as
        /// its own state rather than folded into `missing`, because removing an
        /// entry the user could still paste is a worse mistake than keeping one
        /// they cannot.
        case unknown(String)
    }

    private enum Section: Hashable {
        case items
        /// Only ever holds *Remove Missing Items*, and only exists while
        /// there is something missing to remove.
        case missing
    }

    /// One held location, as the list identifies it.
    ///
    /// The location alone is not an identity: nothing stops the same one
    /// being held twice, and two rows that hash equal is the one way a
    /// snapshot raises rather than draws. `occurrence` counts the identical
    /// locations ahead of this one, which is stable — the only thing that
    /// changes it is removing an earlier copy of the *same* location, and
    /// `FileClipboard.remove` takes every copy at once.
    private struct Entry: Hashable {
        let location: FileLocation
        let occurrence: Int
    }

    private enum Item: Hashable {
        case entry(Entry)
        case removeMissing
    }

    private let clipboard: FileClipboard
    private let session = FileSession.shared
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: TitledTableDataSource<Section, Item>!

    private var items: [FileLocation] = []
    private var statuses: [FileLocation: Status] = [:]
    private var survey: Task<Void, Never>?

    /// Derived rather than stored: `items` is the clipboard's own order and
    /// duplicating it as a second array is a second thing to keep true.
    private var entries: [Entry] {
        var seen: [FileLocation: Int] = [:]
        return items.map { item in
            let occurrence = seen[item, default: 0]
            seen[item] = occurrence + 1
            return Entry(location: item, occurrence: occurrence)
        }
    }

    init(clipboard: FileClipboard) {
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Clipboard")
        trailingNavigationItems = [Self.actionsItem(menu: UIMenu(children: [
            UIAction(
                title: String(localized: "Clear"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.confirmClear()
            },
        ]))]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        table.delegate = self
        buildDataSource()
        view.addSubview(table)
        table.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        installModalDoneButton()
    }

    /// Re-checked every time the screen appears rather than once. The clipboard
    /// outlives the screen, and the interesting case is exactly the one where
    /// something changed while it was closed.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        survey?.cancel()
    }

    // MARK: - List

    private func buildDataSource() {
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        dataSource = TitledTableDataSource(tableView: table) { [weak self] table, indexPath, item in
            let cell = table.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
            cell.accessoryType = .none

            guard case let .entry(entry) = item else {
                var content = UIListContentConfiguration.cell()
                content.text = String(localized: "Remove Missing Items")
                content.textProperties.color = .systemRed
                cell.contentConfiguration = content
                cell.selectionStyle = .default
                return cell
            }

            let status = self?.statuses[entry.location] ?? .checking
            let (detail, color) = Self.detail(for: status)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = entry.location.path.name ?? Self.backendName(entry.location.backend)
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            // Where it came from, which is the whole answer to "which one of
            // the four Info.plists is this". A share's entry names the share.
            content.secondaryText = "\(Self.origin(of: entry.location))\n\(detail)"
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = color
            content.image = UIImage(systemName: Self.symbol(for: status))
            content.imageProperties.tintColor = color == .systemRed ? .systemRed : .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = self?.onReveal == nil ? .none : .default
            return cell
        }
        dataSource.header = { [weak self] section in
            guard let self, section == .items, !self.items.isEmpty else { return nil }
            return summary
        }
        dataSource.footer = { [weak self] section in self?.footer(for: section) }
    }

    /// Refresh section summaries together with the newly received rows.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.items])
        snapshot.appendItems(entries.map(Item.entry), toSection: .items)
        if !missingItems.isEmpty {
            snapshot.appendSections([.missing])
            snapshot.appendItems([.removeMissing], toSection: .missing)
        }
        let existing = Set(dataSource.snapshot().sectionIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: true)
        table.backgroundView = items.isEmpty ? StatusView(content: .message(
            symbol: "doc.on.clipboard",
            title: String(localized: "Clipboard Is Empty"),
            detail: String(localized: "Items you copy or move wait here until you paste them.")
        )) : nil
    }

    // MARK: - State

    private func reload() {
        items = clipboard.items
        statuses = statuses.filter { items.contains($0.key) }
        navigationItem.rightBarButtonItem?.isEnabled = !items.isEmpty
        if dataSource.snapshot().sectionIdentifiers.isEmpty { applySnapshot() }
        startSurvey()
    }

    /// Asks each backend about every held location, one at a time.
    ///
    /// Sequential on purpose. A cut of a few thousand files is a normal thing to
    /// do in a file manager, and firing that many requests at once would queue
    /// them all on the one connection each backend has and stall everything
    /// else using it — for a screen whose entire job is to answer a question
    /// the user is looking at.
    ///
    /// Keep the previous snapshot visible until every status has arrived.
    private func startSurvey() {
        survey?.cancel()
        let items = items
        survey = Task { [weak self] in
            var received: [FileLocation: Status] = [:]
            for item in items {
                guard let self, !Task.isCancelled else { return }
                received[item] = await Self.status(of: item, session: session)
            }
            guard let self, !Task.isCancelled, self.items == items else { return }
            statuses = received
            applySnapshot()
        }
    }

    private static func status(of item: FileLocation, session: FileSession) async -> Status {
        do {
            if item.backend == session.local.id {
                let details = try await session.perform(retryOnDisconnect: true) {
                    try await $0.details(of: session.local.absolutePath(item.path))
                }
                return .present(FileEntry(node: details.node))
            }
            guard let backend = BackendComposition.fileBackends.first(where: { $0.id == item.backend }) else {
                // The share was removed since the copy: nothing can paste it.
                return .missing
            }
            return .present(try await backend.fileService().details(item.path))
        } catch let failure as FilaFailure where failure.code == .notFound || failure.systemError == ENOENT {
            // The one answer worth acting on: the path resolves to nothing, so
            // the promise this entry was is broken and the paste will fail.
            return .missing
        } catch {
            // Anything else — a refusal, a disconnected daemon, a server that
            // did not answer — is not proof the file is gone, and calling it
            // gone would invite the user to remove an entry they could still
            // paste.
            return .unknown(FailureMessage.text(for: error))
        }
    }

    private var missingItems: [FileLocation] {
        items.filter {
            if case .missing? = statuses[$0] {
                true
            } else {
                false
            }
        }
    }

    // MARK: - Actions

    private func remove(_ item: FileLocation) {
        clipboard.remove(item)
        statuses[item] = nil
        reload()
    }

    private func removeMissing() {
        for item in missingItems {
            clipboard.remove(item)
        }
        reload()
    }

    private func confirmClear() {
        let alert = AlertViewController(
            title: String.LocalizationValue("Clear Clipboard?"),
            message: String.LocalizationValue("Your files stay where they are. You will have nothing left to paste.")
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Clear"), attribute: .accent) {
                context.dispose {
                    self?.clipboard.clear()
                    self?.reload()
                }
            }
        }
        present(alert, animated: true)
    }

    private func reveal(_ item: FileLocation) {
        guard let onReveal else { return }
        dismiss(animated: true) { onReveal(item) }
    }

    // MARK: - Text

    /// "Move · 3 items · 2 minutes ago". The operation is the fact people come
    /// here for: a cut that was forgotten about is a move waiting to happen
    /// somewhere unexpected.
    private var summary: String {
        guard !items.isEmpty else { return "" }
        var parts = [clipboard.isCut ? String(localized: "Move") : String(localized: "Copy")]
        parts.append(items.count == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%lld items"), Int64(items.count)))
        if let takenAt = clipboard.takenAt {
            parts.append(takenAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func footer(for section: Section) -> String? {
        guard section == .items else { return nil }
        guard !items.isEmpty else { return nil }
        guard !missingItems.isEmpty else { return nil }
        guard missingItems.count > 1 else {
            return String(
                localized: "One of these items no longer exists. Remove it from the clipboard before pasting."
            )
        }
        return String(
            format: String(
                localized: "%lld of these items no longer exist. Remove them from the clipboard before pasting."
            ),
            Int64(missingItems.count)
        )
    }

    /// The folder an entry came from: an absolute path on the local root,
    /// "share name › folder" on a server.
    private static func origin(of item: FileLocation) -> String {
        let local = FileSession.shared.local
        if item.backend == local.id {
            return (local.absolutePath(item.path) as NSString).deletingLastPathComponent
        }
        let parent = item.path.parent?.description ?? ""
        return parent.isEmpty ? backendName(item.backend) : backendName(item.backend) + " › " + parent
    }

    private static func backendName(_ id: BackendID) -> String {
        BackendComposition.backends.first { $0.id == id }?.root.displayName ?? id.rawValue
    }

    private static func detail(for status: Status) -> (String, UIColor) {
        switch status {
        case .checking:
            return (String(localized: "Checking…"), .tertiaryLabel)
        case let .present(entry):
            let kind = entry.entersDirectory ? String(localized: "Folder") : String(localized: "File")
            guard let size = entry.size, !entry.entersDirectory else { return (kind, .secondaryLabel) }
            return ("\(kind) · \(FilePresentation.byteLabel(size))", .secondaryLabel)
        case .missing:
            return (String(localized: "This item no longer exists."), .systemRed)
        case let .unknown(reason):
            return (reason, .secondaryLabel)
        }
    }
}

extension ClipboardViewController: UITableViewDelegate {
    private static func symbol(for status: Status) -> String {
        switch status {
        case .checking, .unknown: "questionmark.circle"
        case .missing: "exclamationmark.triangle"
        case let .present(entry): entry.entersDirectory ? "folder" : "doc"
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .entry(entry): reveal(entry.location)
        case .removeMissing: removeMissing()
        case nil: break
        }
    }

    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .entry(entry)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let item = entry.location
        // "Remove", never "Delete": this takes the entry off the clipboard and
        // touches nothing on disk, and a red Delete on a file manager's screen
        // had better mean the other thing.
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove")
        ) { [weak self] _, _, done in
            self?.remove(item)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
