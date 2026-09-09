import FilaBackendUI
import FilaLog
import FilaProtocol
import SnapKit
import Then
import UIKit

/// The log screen: both processes on one timeline.
///
/// Present it wrapped, from anywhere:
///
///     presentAsSheet(UINavigationController(rootViewController: LogViewController()))
///
/// or push it onto an existing stack — it brings its own Close button only when
/// it is presented. It needs nothing passed in; it reads `FilaLog`'s ring for
/// the app's lines and polls `filad` for its own.
///
/// The app's lines and the daemon's are merged by timestamp rather than shown
/// in two tabs, because the interesting sequence is a request and the daemon's
/// handling of it, in order — "the app asked to delete this, the guard refused
/// it" is one story and a source picker cuts it in half. The tag on each row
/// says whose line it is.
///
/// ## Why it stays fast with a full buffer
///
/// A collection view with a diffable data source, and two decisions that keep
/// that combination from being the wrong one for a log:
///
/// - **Rows fit their text, up to three message lines.** A short message does
///   not reserve empty lines. Longer entries open in a selectable detail page;
///   bounded previews keep a large diagnostic payload out of row layout.
/// - **Applies are batched, never per line.** Lines arrive continuously —
///   verbose writes one per XPC round trip — and a snapshot per line would
///   melt. Everything lands through `refresh()`, which runs once a second, so
///   a snapshot covers a second's worth however many lines that was.
///
/// The item type is the record itself: `sequence` is unique per process and
/// `source` separates the two, so identity is stable and never derived from a
/// row index. Eviction — the ring's, and this screen's own cap — is a delete
/// at the front, which is the diff a diffable data source is best at.
final class LogViewController: UIViewController {
    /// How many rows are kept. The app's own lines are already bounded by
    /// `FilaLog`'s ring; this bounds what accumulates from the daemon over a
    /// long session, so leaving the screen open during a big verbose copy
    /// cannot grow without limit.
    private static let maximumRowCount = 20000

    private static let pollInterval: TimeInterval = 1

    private let session = FileSession.shared
    private let search = UISearchController(searchResultsController: nil)
    private let droppedNotice = UIListContentView(configuration: .groupedFooter())

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FilaLog.Record>!

    /// Everything held, oldest first. Merged from two sources, so it is sorted
    /// rather than appended in place.
    private var records: [FilaLog.Record] = []
    /// What the snapshot carries: `records` after the level, process and text
    /// filters. A filter change is a snapshot swap, not a reload.
    private var visible: [FilaLog.Record] = []

    private var appCursor: UInt64 = 0
    private var daemonCursor: UInt64 = 0
    private var daemonDropped: UInt64 = 0

    private var sourceFilter: FilaLog.Source?
    private var searchText = ""

    /// True while the list is parked at the bottom, which is where a log wants
    /// to be. A scroll upwards turns it off — otherwise reading anything older
    /// than a second is impossible — and the Newest button turns it back on.
    private var isFollowing = true
    private var timer: Timer?
    private var appearanceTask: Task<Void, Never>?
    private var isFetching = false
    /// A compact row's estimated height is also the follow-mode tolerance;
    /// scrolling does not need to construct fonts on every event.
    private var rowHeight = LogRowCell.height()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Log")
        updateBarButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout()).then {
            $0.delegate = self
            $0.alwaysBounceVertical = true
            $0.contentInsetAdjustmentBehavior = .never
            $0.contentInset.bottom = FilaUI.Spacing.settingsTail
        }
        droppedNotice.isHidden = true
        let content = UIStackView(arrangedSubviews: [collectionView, droppedNotice])
        content.axis = .vertical
        view.addSubview(content)
        buildDataSource()
        content.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Filter")
        navigationItem.searchController = search
        // A log is read from the bottom; a search bar that hides on scroll
        // takes the filter away exactly when someone scrolls up to look.
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        installModalDoneButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appearanceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
            guard let self else { return }
            await refresh(animated: true)
            guard !Task.isCancelled else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearanceTask?.cancel()
        appearanceTask = nil
        timer?.invalidate()
        timer = nil
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.preferredContentSizeCategory != previous?.preferredContentSizeCategory else { return }
        // The row height is derived from the text style, so a Dynamic Type
        // change is a new layout rather than a new snapshot.
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
    }

    // MARK: - List

    /// Message-first rows follow iGhostVT's journal: intrinsic text height,
    /// a tight metadata line below, and no reserved blank message lines.
    private func makeLayout() -> UICollectionViewLayout {
        rowHeight = LogRowCell.height()
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(rowHeight))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: size,
            subitems: [NSCollectionLayoutItem(layoutSize: size)]
        )
        return UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
    }

    private func buildDataSource() {
        let cell = UICollectionView.CellRegistration<LogRowCell, FilaLog.Record> { cell, _, record in
            cell.show(record)
        }
        dataSource = UICollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { collection, indexPath, record in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: record)
        }
    }

    // MARK: - Polling

    /// Merge both sources before applying a single snapshot for this poll.
    private func refresh(animated: Bool = false) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        let answer = try? await session.perform {
            try await $0.fetchLog(since: self.daemonCursor, level: LogPreferences.level)
        }
        guard !Task.isCancelled, viewIfLoaded?.window != nil,
              navigationController?.topViewController === self else { return }
        let (appRecords, _) = FilaLog.snapshot(since: appCursor)
        if let last = appRecords.last {
            appCursor = last.sequence
        }
        if let answer {
            if let last = answer.records.last {
                daemonCursor = last.sequence
            }
            daemonDropped = answer.dropped
            updateDroppedNotice()
        }
        add(appRecords + (answer?.records ?? []), animated: animated)
    }

    private func add(_ incoming: [FilaLog.Record], animated: Bool) {
        records.append(contentsOf: incoming)
        // Two independent sequences on one timeline, so the order is the
        // clock's; source and sequence break a tie so an apply never shuffles
        // rows the reader was looking at.
        //
        // ponytail: the accumulated list is re-sorted per batch, O(n log n) at
        // twenty thousand rows once a second. The poll interval is what keeps
        // that off the critical path; a merge into the sorted array is the fix
        // if it ever shows up.
        records.sort { a, b in
            (a.time, a.source.rawValue, a.sequence) < (b.time, b.source.rawValue, b.sequence)
        }
        if records.count > Self.maximumRowCount {
            // A delete at the front, which is the shape diffable handles best.
            records.removeFirst(records.count - Self.maximumRowCount)
        }
        applyFilter(animated: animated)
    }

    /// The filters, then one snapshot. Every path that changes what is shown
    /// comes through here — a level change, a keystroke, a new batch — so
    /// there is exactly one place an apply happens.
    private func applyFilter(animated: Bool = false) {
        let level = LogPreferences.level
        let source = sourceFilter
        let text = searchText
        visible = records.filter { record in
            guard record.level >= level else { return false }
            guard source == nil || record.source == source else { return false }
            guard !text.isEmpty else { return true }
            return record.message.localizedCaseInsensitiveContains(text)
        }
        // Two different empties, and the app's own status panel already knows
        // how to say them apart: a log with nothing in it yet is a different
        // fact from a filter that matches none of what is there.
        collectionView.showStatus(status)

        var snapshot = NSDiffableDataSourceSnapshot<Int, FilaLog.Record>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible)
        // Animate the initial reveal after the navigation transition; live polls stay steady.
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            guard let self, isFollowing else { return }
            scrollToNewest(animated: false)
        }
    }

    /// Nil once there are rows. Nothing here is ever `.loading`: the ring is
    /// read synchronously and the daemon's lines are a bonus that arrives when
    /// it arrives — a spinner would be claiming to wait for something.
    private var status: StatusView.Content? {
        guard visible.isEmpty else { return nil }
        guard records.isEmpty else {
            return .message(
                symbol: "line.3.horizontal.decrease",
                title: String(localized: "No Matching Lines"),
                detail: String(localized: "Try different filters.")
            )
        }
        return .message(symbol: "text.alignleft", title: String(localized: "Nothing Logged Yet"))
    }

    private func scrollToNewest(animated: Bool) {
        guard !visible.isEmpty else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: visible.count - 1, section: 0),
            at: .bottom,
            animated: animated
        )
    }

    // MARK: - Bar

    private func updateBarButtons() {
        if let item = navigationItem.rightBarButtonItem {
            item.menu = buildMenu()
        } else {
            let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: buildMenu())
            item.accessibilityLabel = String(localized: "More")
            navigationItem.rightBarButtonItem = item
        }
    }

    /// The daemon's ring wrapped while nobody was polling, so there is a hole.
    /// Said out loud rather than left as a log that quietly skips a minute.
    private func updateDroppedNotice() {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = daemonDropped == 0 ? nil : String(
            format: String(localized: "%lld earlier lines from filad were discarded."),
            Int64(daemonDropped)
        )
        droppedNotice.configuration = content
        droppedNotice.isHidden = daemonDropped == 0
    }

    /// Level, process, and the two things to do with a buffer.
    ///
    /// The level is one control doing two jobs: it is what the list shows *and*
    /// what both processes capture at. Splitting them would mean explaining the
    /// difference between a log that has no verbose lines and a log that is
    /// hiding them, and "turn it up, reproduce it, read it" is the whole
    /// workflow this screen exists for.
    private func buildMenu() -> UIMenu {
        let levels = UIMenu(
            title: String(localized: "Level"),
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            children: FilaLog.Level.allCases.reversed().map { level in
                UIAction(
                    title: Self.title(for: level),
                    state: LogPreferences.level == level ? .on : .off
                ) { [weak self] _ in
                    LogPreferences.level = level
                    FilaLog.minimumLevel = level
                    // The daemon writes the same line when its own level
                    // changes. Without this one, a log that starts at verbose
                    // halfway down looks like the app was restarted. Written
                    // *at* the new level so raising the floor cannot drop the
                    // line that says the floor was raised.
                    FilaLog.log(level, "log level is now \(level.tag)")
                    self?.updateBarButtons()
                    self?.applyFilter()
                }
            }
        )
        let sources = UIMenu(
            title: String(localized: "Process"),
            image: UIImage(systemName: "app.connected.to.app.below.fill"),
            children: [nil, FilaLog.Source.app, FilaLog.Source.daemon].map { source in
                UIAction(
                    title: source?.name ?? String(localized: "Both"),
                    state: sourceFilter == source ? .on : .off
                ) { [weak self] _ in
                    self?.sourceFilter = source
                    self?.updateBarButtons()
                    self?.applyFilter()
                }
            }
        )
        let actions = FilaMenu.groups([
            UIAction(
                title: String(localized: "Jump to Latest"),
                image: UIImage(systemName: "arrow.down.to.line")
            ) { [weak self] _ in
                self?.isFollowing = true
                self?.scrollToNewest(animated: true)
            },
            UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.share() },
        ], [
            UIAction(
                title: String(localized: "Clear"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.clear() },
        ])
        return UIMenu(children: FilaMenu.groups([levels, sources]) + actions)
    }

    // MARK: - Actions

    /// The share sheet owns this export until its completion callback.
    private func share() {
        let text = visible.map(Self.exportLine).joined(separator: "\n")
        Task { [weak self] in
            do {
                let directory = try await FileSession.shared.makeTemporaryDirectory()
                var handedOff = false
                defer {
                    if !handedOff {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
                guard let self, viewIfLoaded?.window != nil,
                      navigationController?.topViewController === self,
                      presentedViewController == nil else { return }
                let url = directory.appendingPathComponent("fila.log")
                try text.write(to: url, atomically: false, encoding: .utf8)
                let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                controller.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: directory)
                }
                anchor(controller, to: collectionView)
                present(controller, animated: true)
                handedOff = true
            } catch { FilaLog.error("Log export failed: \(error)") }
        }
    }

    /// Empties the view and the app's ring. The daemon's ring is left alone:
    /// its cursor only ever moves forward, so nothing already shown comes back,
    /// and reaching into another process to erase its history is not something
    /// a Clear button should do.
    private func clear() {
        FilaLog.clear()
        let (remaining, _) = FilaLog.snapshot()
        appCursor = remaining.last?.sequence ?? appCursor
        records = []
        daemonDropped = 0
        isFollowing = true
        updateDroppedNotice()
        applyFilter()
    }

    // MARK: - Text

    private static func title(for level: FilaLog.Level) -> String {
        switch level {
        case .verbose: String(localized: "Verbose")
        case .info: String(localized: "Info")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        }
    }

    static func exportLine(_ record: FilaLog.Record) -> String {
        "\(timeText(record.time)) \(record.level.tag) \(record.source.name) \(record.message)"
    }

    /// `HH:mm:ss.SSS` without a `DateFormatter`: this runs for every visible
    /// row on every apply, and a formatter is two orders of magnitude dearer
    /// than `localtime_r`.
    static func timeText(_ time: Double) -> String {
        var seconds = time_t(time)
        var parts = tm()
        localtime_r(&seconds, &parts)
        let milliseconds = Int((time - time.rounded(.down)) * 1000)
        return "\(pad(Int(parts.tm_hour), 2)):\(pad(Int(parts.tm_min), 2)):\(pad(Int(parts.tm_sec), 2))"
            + ".\(pad(milliseconds, 3))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

extension LogViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let record = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(LogRecordViewController(record: record), animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Within a row of the bottom counts as at the bottom: a rubber-band
        // bounce must not silently turn following off.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let distance = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height - scrollView.contentOffset.y
        isFollowing = distance <= rowHeight
    }

    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let record = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = LogViewController.exportLine(record)
                },
            ])
        }
    }
}

extension LogViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != searchText else { return }
        searchText = text
        applyFilter()
    }
}

/// Where the level survives a relaunch — and only the level.
///
/// Deliberately not in `AppPreferences`: that is the user's settings and this is a
/// diagnostic switch, and the two get trimmed and migrated on different
/// schedules. Verbose is not the default and never becomes it: it writes a line
/// per XPC round trip, so a build that shipped with it on would be a build that
/// logs a thousand lines a second while the user does nothing in particular.
enum LogPreferences {
    private static let key = "wiki.qaq.fila.log.level"

    static var level: FilaLog.Level {
        get {
            guard let stored = UserDefaults.standard.object(forKey: key) as? Int,
                  let level = FilaLog.Level(rawValue: UInt8(truncatingIfNeeded: stored)) else { return .info }
            return level
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: key) }
    }
}
