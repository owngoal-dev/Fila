#if canImport(UIKit)
import FilaBackendKit
import FilaLog
import UIKit

/// The list every backend root is shown with: a collection view of `Item`
/// rows, one reload owner, and one subscription to the backend's changes.
///
/// What is shared is the lifecycle, not the content. A subclass supplies
/// the layout, the cells, the stream of batches to show and the changes
/// that should trigger another listing; the base keeps the rules every
/// list follows: the first load streams into place as it arrives, a refresh
/// keeps the rows on screen until the complete replacement is ready and
/// then applies one diff, a hint that lands mid-listing waits until the
/// current listing has settled, and a failure with rows already showing is
/// reported rather than replacing them with a blank screen.
///
/// Nothing here knows what an item is. There is no file switch, no
/// catalogue switch and no preference read: those belong to the subclass
/// and to the backend behind it.
@MainActor
open class BackendListViewController<Item: Hashable & Sendable>: TabContentViewController {
    public private(set) var collectionView: UICollectionView!
    public private(set) var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    public let refresher = UIRefreshControl()

    /// Every item received by the latest completed or streaming load, in
    /// arrival order. `visible` is `arrange(items)`.
    public private(set) var items: [Item] = []
    public private(set) var visible: [Item] = []
    /// A listing is in flight. Rows already received count as content. True
    /// from construction: until the first listing lands there is nothing to
    /// show but the wait, and an empty panel before it would call a folder
    /// empty before anyone has looked.
    public private(set) var isLoading = true
    /// Why there are no rows, when a load failed before any arrived.
    public private(set) var loadFailure: Error?
    /// The load stopped at `maximumItemCount`; the list is incomplete.
    public private(set) var isTruncated = false
    /// How many items a listing may show. Consumers needing a complete
    /// list must not read one from here.
    open var maximumItemCount: Int { 50_000 }

    /// What the listing trace calls this list. At verbose level every load
    /// writes where its time went — the wait for each batch, the cost of
    /// each apply, the tail after the last row — so a slow folder can be
    /// read off the log screen rather than guessed at. A browser answers
    /// with its directory.
    open var traceName: String { String(describing: type(of: self)) }

    public private(set) var loadTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?

    /// While true, reloads are held rather than started — a context menu
    /// animating shut must not have its cell pulled out from under it. The
    /// held reload runs when this goes back to false.
    public var holdsReloads = false {
        didSet {
            guard !holdsReloads, reloadWasHeld else { return }
            reloadWasHeld = false
            reload()
        }
    }

    private var reloadWasHeld = false
    private var hasAppeared = false

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        loadTask?.cancel()
        changesTask?.cancel()
    }

    // MARK: - Hooks

    /// The list's layout. A plain list with a clear section background by
    /// default, so the status panel behind the rows stays visible.
    open func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    /// The cell for one item. Registrations belong to the subclass, made at
    /// construction or before `super.viewDidLoad()` — never lazily from
    /// here: UIKit refuses a registration created inside the cell provider.
    open func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: Item) -> UICollectionViewCell {
        fatalError("makeCell(_:at:for:) must be overridden")
    }

    /// The batches to show, in order. A local directory yields its pages; a
    /// catalogue yields one batch. The stream is consumed once per reload.
    open func load() -> AsyncThrowingStream<[Item], Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Hints that the content changed; each element starts a reload once
    /// the current one has settled. Nil means the list reloads only when
    /// it appears and when asked.
    open func changes() async throws -> AsyncThrowingStream<Void, Error>? {
        nil
    }

    /// Filter and order for display. Called on every snapshot.
    open func arrange(_ items: [Item]) -> [Item] {
        items
    }

    /// What to show behind the rows: nil when there are rows to show.
    open var statusContent: StatusView.Content? {
        nil
    }

    /// What the status panel's button does.
    open func statusAction() {}

    /// What a pull on the refresh control asks for: `reload()`. A subclass
    /// that counts a deliberate refresh as use of the screen does that first.
    open func refreshRequested() {
        reload()
    }

    /// A load is starting from nothing: the rows are about to be replaced
    /// by whatever streams in. Reset per-listing state here.
    open func willStartInitialLoad() {}

    /// A load ended in an error. `hadRows` says whether the screen already
    /// shows content — a refresh that failed halfway — or nothing, in which
    /// case the failure is already the status panel.
    open func loadDidFail(_ error: Error, hadRows: Bool) {}

    /// The final snapshot of a load has been applied. Follow-up work that
    /// wants the rows in place — decorations, footers — goes here. `failed`
    /// says the load ended in `loadDidFail`, with or without rows: `received`
    /// is then how far it got, not what the folder holds.
    open func loadDidComplete(received: Int, elapsed: TimeInterval, failed: Bool) async {}

    /// A snapshot was applied: streaming page, final page or a rearrange.
    open func snapshotDidApply() {}

    // MARK: - Lifecycle

    override open func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.alwaysBounceVertical = true
        collectionView.refreshControl = refresher
        refresher.addAction(UIAction { [weak self] _ in self?.refreshRequested() }, for: .valueChanged)
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collection, indexPath, item in
            self?.makeCell(collection, at: indexPath, for: item) ?? UICollectionViewCell()
        }
        applySnapshot(animated: false)
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        observeChanges()
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        changesTask?.cancel()
        changesTask = nil
        loadTask?.cancel()
    }

    /// One subscription for as long as the screen is up. The first hint
    /// lands at once and is the initial listing; every later one is a reload
    /// under the usual rules. Without a change stream the screen reloads on
    /// appearance and on request only.
    private func observeChanges() {
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            do {
                guard let self, let stream = try await changes() else {
                    self?.reload()
                    return
                }
                for try await _ in stream {
                    guard !Task.isCancelled else { return }
                    reload()
                    // One listing at a time: a hint that lands mid-listing
                    // waits in the stream's one-slot buffer and starts the
                    // next reload only after this one has settled.
                    await loadTask?.value
                }
            } catch {
                // A subscription that ended keeps the rows it had; the next
                // appearance subscribes again.
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    // MARK: - Loading

    /// Lists again. On screen only: a retained tab reloads when it appears,
    /// without competing with the one the user is viewing.
    public func reload() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self else { return }
        guard !holdsReloads else {
            reloadWasHeld = true
            return
        }
        // A completed task remains here, so a loaded empty list also keeps
        // its current presentation when another request starts.
        let keepsContent = loadTask != nil
        loadTask?.cancel()
        loadFailure = nil
        isLoading = true
        if !keepsContent {
            willStartInitialLoad()
            applySnapshot(animated: false)
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            var pending: [Item] = []
            var received = 0
            var truncated = false
            var lastApply = Date.distantPast
            var failed = false
            let startedAt = Date()
            let limit = maximumItemCount
            let traces = FilaLog.isEnabled(.verbose)
            var batches = 0
            var requestedAt = DispatchTime.now()
            do {
                for try await batch in load() {
                    // From "asked for the next batch" to "batch in hand":
                    // the backend's share of the wall clock. Reset at the end
                    // of the body, after this batch's apply.
                    defer { requestedAt = .now() }
                    if traces {
                        batches += 1
                        FilaLog.verbose(
                            "list \(traceName): batch \(batches) n=\(batch.count)"
                                + " wait=\(milliseconds(since: requestedAt))ms"
                        )
                    }
                    // Only the latest reload owns the rows. During a refresh,
                    // a partial listing must not remove later pages.
                    guard !Task.isCancelled else { return }
                    let remaining = limit - received
                    pending.append(contentsOf: batch.prefix(remaining))
                    received += min(remaining, batch.count)
                    if batch.count > remaining {
                        truncated = true
                        break
                    }
                    guard !keepsContent else { continue }
                    // Re-arranging the accumulated list on every apply is
                    // O(n log n) per batch; the throttle keeps that off the
                    // critical path of a huge directory streaming in.
                    guard Date().timeIntervalSince(lastApply) > 0.15 else { continue }
                    items.append(contentsOf: pending)
                    pending = []
                    lastApply = Date()
                    applySnapshot(animated: false)
                }
                guard !Task.isCancelled else { return }
                isTruncated = truncated
                if keepsContent {
                    items = pending
                } else {
                    items.append(contentsOf: pending)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // With nothing on screen the refusal *is* the screen, and an
                // alert dismissed over a blank list leaves the user with the
                // blank list. With rows already listed it is a refresh that
                // went wrong halfway, which nothing on screen would show.
                if items.isEmpty {
                    loadFailure = error
                }
                failed = true
                loadDidFail(error, hadRows: !items.isEmpty)
            }
            guard !Task.isCancelled else { return }
            isLoading = false
            await withCheckedContinuation { continuation in
                self.applySnapshot(animated: keepsContent) { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            refresher.endRefreshing()
            let completedAt = DispatchTime.now()
            await loadDidComplete(received: received, elapsed: Date().timeIntervalSince(startedAt), failed: failed)
            if traces {
                FilaLog.verbose(
                    "list \(traceName): complete received=\(received) batches=\(batches)"
                        + " rows=\(visible.count) in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms"
                        + " tail=\(milliseconds(since: completedAt))ms"
                )
            }
        }
    }

    /// Applies `arrange(items)` as the list's one section, then the status
    /// panel behind it. `reloadingData` redraws every row from scratch
    /// instead of diffing: `apply` with an identical snapshot is an empty
    /// diff that never asks the cell provider for anything, so a layout or
    /// unit change that leaves the items alone needs the reload.
    public func applySnapshot(animated: Bool, reloadingData: Bool = false, completion: (() -> Void)? = nil) {
        guard let dataSource else {
            completion?()
            return
        }
        let traces = FilaLog.isEnabled(.verbose)
        let startedAt = DispatchTime.now()
        visible = arrange(items)
        let arrangedAt = DispatchTime.now()
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible)
        if reloadingData {
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        } else {
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        if traces {
            FilaLog.verbose(
                "list \(traceName): apply rows=\(visible.count) of \(items.count)"
                    + " arrange=\(milliseconds(since: startedAt, until: arrangedAt))ms"
                    + " snapshot=\(milliseconds(since: arrangedAt))ms"
                    + (reloadingData ? " reload" : animated ? " animated" : "")
            )
        }
        collectionView.showStatus(statusContent) { [weak self] in self?.statusAction() }
        snapshotDidApply()
    }

    /// Replaces what is shown without a load: what a subclass calls when
    /// its arrangement changed but the content did not.
    public func rearrange(animated: Bool) {
        applySnapshot(animated: animated)
    }

    /// Redraws every row from scratch, keeping the content.
    public func redraw() {
        applySnapshot(animated: false, reloadingData: true)
    }

    /// Reconfigures every visible row — decorations arrived, say.
    public func reconfigureVisibleItems() async {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        await dataSource.apply(snapshot, animatingDifferences: false)
    }
}

/// Wall-clock milliseconds between two marks, to one decimal, for the trace.
private func milliseconds(since start: DispatchTime, until end: DispatchTime = .now()) -> String {
    String(format: "%.1f", Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
}
#endif
