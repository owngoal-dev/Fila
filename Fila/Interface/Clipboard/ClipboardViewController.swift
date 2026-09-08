import AlertController
import FilaClient
import FilaProtocol
import SnapKit
import UIKit

/// What Copy and Move are actually holding.
///
/// Without this screen the clipboard is invisible: Paste is enabled or it is
/// greyed out, and that is the whole of the feedback. Worse, the thing it holds
/// is a list of *paths*, and a path is a promise that breaks quietly — the file
/// moves, or another tab deletes it, and the only symptom is a paste that fails
/// later with an `errno` and no explanation of which of the six items was the
/// problem.
///
/// So every entry is checked against the daemon when the screen appears, and an
/// entry that no longer resolves says so here, in the one place where the user
/// can do something about it: remove it, or clear the lot. A missing entry is
/// never dropped silently — a clipboard that quietly shrinks is worse than one
/// that is wrong, because the user has no way to notice either.
///
/// The browser presents this in a navigation controller from its pending bar or menu.
final class ClipboardViewController: UIViewController {
    /// Where an entry goes when it is tapped. Set by whoever presents this: the
    /// browser owns navigation and this screen knows nothing about it.
    var onReveal: ((String) -> Void)?

    /// What the daemon says about one held path, right now.
    private enum Status {
        case checking
        case present(FileDetails)
        /// The path resolves to nothing. The promise is broken.
        case missing
        /// It is there, or it may be — the daemon refused to say. Reported as
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

    /// One held path, as the list identifies it.
    ///
    /// The path alone is not an identity: nothing stops the same path being held
    /// twice, and two rows that hash equal is the one way a snapshot raises
    /// rather than draws. `occurrence` counts the identical paths ahead of this
    /// one, which is stable — the only thing that changes it is removing an
    /// earlier copy of the *same* path, and `FileClipboard.remove` takes every copy
    /// of a path at once.
    private struct Entry: Hashable {
        let path: String
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

    private var paths: [String] = []
    private var statuses: [String: Status] = [:]
    private var survey: Task<Void, Never>?

    /// Derived rather than stored: `paths` is the clipboard's own order and
    /// duplicating it as a second array is a second thing to keep true.
    private var entries: [Entry] {
        var seen: [String: Int] = [:]
        return paths.map { path in
            let occurrence = seen[path, default: 0]
            seen[path] = occurrence + 1
            return Entry(path: path, occurrence: occurrence)
        }
    }

    init(clipboard: FileClipboard) {
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Clipboard")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Clear"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.confirmClear()
                },
            ])
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "More")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

            let status = self?.statuses[entry.path] ?? .checking
            let (detail, color) = Self.detail(for: status)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = URL(fileURLWithPath: entry.path).lastPathComponent
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            // The directory it came from, which is the whole answer to "which one
            // of the four Info.plists is this".
            content.secondaryText = "\((entry.path as NSString).deletingLastPathComponent)\n\(detail)"
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
            guard let self, section == .items, !self.paths.isEmpty else { return nil }
            return self.summary
        }
        dataSource.footer = { [weak self] section in self?.footer(for: section) }
    }

    /// Rebuilds the whole list.
    ///
    /// `applySnapshotUsingReloadData` rather than a plain apply: the header
    /// counts the entries and the footer counts the missing ones, and a plain
    /// apply only redraws the sections it moved — so removing one entry would
    /// leave "Move · 3 items" over two rows. Reloading is also exactly what this
    /// screen did before, so nothing gained an animation it did not have.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.items])
        snapshot.appendItems(entries.map(Item.entry), toSection: .items)
        if !missingPaths.isEmpty {
            snapshot.appendSections([.missing])
            snapshot.appendItems([.removeMissing], toSection: .missing)
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
        table.backgroundView = paths.isEmpty ? StatusView(content: .message(
            symbol: "doc.on.clipboard", title: String(localized: "Clipboard Is Empty"),
            detail: String(localized: "Items you copy or move wait here until you paste them.")
        )) : nil
    }

    /// One answer landing changes one row and nothing else on the screen.
    /// Every occurrence of the path, because the status is the path's.
    private func reconfigure(_ path: String) {
        var snapshot = dataSource.snapshot()
        let rows = snapshot.itemIdentifiers.filter {
            if case let .entry(entry) = $0 { return entry.path == path }
            return false
        }
        guard !rows.isEmpty else { return }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - State

    private func reload() {
        paths = clipboard.paths
        statuses = statuses.filter { paths.contains($0.key) }
        navigationItem.rightBarButtonItem?.isEnabled = !paths.isEmpty
        applySnapshot()
        startSurvey()
    }

    /// Asks the daemon about every held path, one at a time.
    ///
    /// Sequential on purpose. A cut of a few thousand files is a normal thing to
    /// do in a file manager, and firing that many `statPath` requests at once
    /// would queue them all on the one connection the app has and stall
    /// everything else using it — for a screen whose entire job is to answer a
    /// question the user is looking at.
    ///
    /// The whole table is reloaded only when an answer is one that changes
    /// something outside its own row: the footer counts the missing entries and
    /// the second section offers to remove them. Everything else touches one row.
    private func startSurvey() {
        survey?.cancel()
        let paths = paths
        survey = Task { [weak self] in
            for path in paths {
                if Task.isCancelled { return }
                guard let self else { return }
                let status = await Self.status(of: path, session: self.session)
                guard !Task.isCancelled, self.paths == paths else { return }
                let wasMissing = self.missingPaths.contains(path)
                self.statuses[path] = status
                if case .missing = status, !wasMissing {
                    self.applySnapshot()
                } else {
                    self.reconfigure(path)
                }
            }
        }
    }

    private static func status(of path: String, session: FileSession) async -> Status {
        do {
            return .present(try await session.perform(retryOnDisconnect: true) {
                try await $0.details(of: path)
            })
        } catch let failure as FilaFailure where failure.code == .notFound || failure.systemError == ENOENT {
            // The one answer worth acting on: the path resolves to nothing, so
            // the promise this entry was is broken and the paste will fail.
            return .missing
        } catch {
            // Anything else — a refusal, a disconnected daemon — is not proof
            // the file is gone, and calling it gone would invite the user to
            // remove an entry they could still paste.
            return .unknown(FailureMessage.text(for: error))
        }
    }

    private var missingPaths: [String] {
        paths.filter { if case .missing? = statuses[$0] { return true } else { return false } }
    }

    // MARK: - Actions

    private func remove(_ path: String) {
        clipboard.remove(path)
        statuses[path] = nil
        reload()
    }

    private func removeMissing() {
        for path in missingPaths { clipboard.remove(path) }
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

    private func reveal(_ path: String) {
        guard let onReveal else { return }
        dismiss(animated: true) { onReveal(path) }
    }

    // MARK: - Text

    /// "Move · 3 items · 2 minutes ago". The operation is the fact people come
    /// here for: a cut that was forgotten about is a move waiting to happen
    /// somewhere unexpected.
    private var summary: String {
        guard !paths.isEmpty else { return "" }
        var parts = [clipboard.isCut ? String(localized: "Move") : String(localized: "Copy")]
        parts.append(paths.count == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%lld items"), Int64(paths.count)))
        if let takenAt = clipboard.takenAt {
            parts.append(takenAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func footer(for section: Section) -> String? {
        guard section == .items else { return nil }
        guard !paths.isEmpty else { return nil }
        guard !missingPaths.isEmpty else { return nil }
        guard missingPaths.count > 1 else {
            return String(
                localized: "One of these items no longer exists. Remove it from the clipboard before pasting."
            )
        }
        return String(
            format: String(
                localized: "%lld of these items no longer exist. Remove them from the clipboard before pasting."
            ),
            Int64(missingPaths.count)
        )
    }

    private static func detail(for status: Status) -> (String, UIColor) {
        switch status {
        case .checking:
            return (String(localized: "Checking…"), .tertiaryLabel)
        case let .present(details):
            let kind = PropertiesViewController.name(of: details.node.kind)
            guard details.node.kind != .directory else { return (kind, .secondaryLabel) }
            let size = FilePresentation.byteLabel(details.node.size)
            return ("\(kind) · \(size)", .secondaryLabel)
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
        case .checking, .unknown: return "questionmark.circle"
        case .missing: return "exclamationmark.triangle"
        case let .present(details): return details.node.isNavigable ? "folder" : "doc"
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .entry(entry): reveal(entry.path)
        case .removeMissing: removeMissing()
        case nil: break
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .entry(entry)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let path = entry.path
        // "Remove", never "Delete": this takes the path off the clipboard and
        // touches nothing on disk, and a red Delete on a file manager's screen
        // had better mean the other thing.
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove")
        ) { [weak self] _, _, done in
            self?.remove(path)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
