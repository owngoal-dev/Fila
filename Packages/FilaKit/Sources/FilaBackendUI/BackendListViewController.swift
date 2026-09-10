#if canImport(UIKit)
import FilaBackendKit
import FilaLog
import UIKit

/// A screen that can start fetching before it is pushed, so the push lands
/// on content rather than on a wait that turns into content a moment later.
///
/// The shell calls `prepare(within:)` and pushes when it returns: with the
/// first rows applied if they came inside the budget, with the loading
/// status if they did not — and in that case the rows animate in when they
/// land. The fetch runs to completion either way.
@MainActor
public protocol PreparableContent: AnyObject {
    func prepare(within budget: TimeInterval) async
    /// `prepare` has run: a push of this screen need not wait again.
    var isPrepared: Bool { get }
}

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
open class BackendListViewController<Item: Hashable & Sendable>: TabContentViewController, PreparableContent {
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

    /// The most new rows one streaming apply hands over. A diff costs a
    /// fixed price plus a few microseconds per inserted row, and the price
    /// differs by device and by whether cells are on screen, so this is
    /// tuned as the load goes: each apply's measured cost scales the next
    /// chunk toward `applyTarget`, never over the budget a push waits for.
    private var applyRowLimit = BackendListPacing.initialRowLimit

    /// A load started by `prepare` is this screen's initial listing: the
    /// first hint of the change subscription must not start a second one.
    private var preparedLoadPending = false

    /// Rows are on screen, or the load ended without any: what a push
    /// waits for. Resumed once, then true for the screen's life.
    private var hasSettled = false
    private var settledWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Bumped by every apply. An arrangement computed off the main thread
    /// lands only if nothing applied while it was being computed.
    private var applyGeneration = 0

    /// Rows a load has received and not yet handed to `items`.
    private var pendingRows: [Item] = []
    /// When the load's last streaming apply was, nil before its first.
    private var lastApplyAt: DispatchTime?
    /// While a push is waiting, the first apply is held until here, so
    /// everything that lands inside the budget goes up together and the
    /// rows the transition shows are not reordered by the batch after it.
    /// The deadline, or completion, flushes.
    private var firstApplyHeldUntil: DispatchTime?

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

    /// The same arrangement as a value that can run off the main thread: a
    /// pure function over the items, with the preferences it needs captured
    /// at the moment it is asked for. A streaming or final apply of a load
    /// sorts through this when it is given, so twenty thousand names never
    /// cost the main thread a frame. Nil — the default — arranges on the
    /// main thread through `arrange`, which is right for a list that is
    /// small or already ordered.
    open func arranger() -> (@Sendable ([Item]) -> [Item])? {
        nil
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
    /// lands at once and is the initial listing — unless `prepare` already
    /// started that listing before the push, in which case the hint is
    /// spent on it; every later one is a reload under the usual rules.
    /// Without a change stream the screen reloads on appearance and on
    /// request only.
    private func observeChanges() {
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            guard let self else { return }
            // One appearance spends the prepared load, whatever happens to
            // the subscription: a flag that outlived this turn would swallow
            // the first hint of every later appearance — the one that
            // re-lists the folder — and a screen whose prepared load was
            // cancelled on the way out would never list again.
            let prepared = preparedLoadPending && loadTask?.isCancelled == false
            preparedLoadPending = false
            do {
                guard let stream = try await changes() else {
                    if !prepared {
                        reload()
                    }
                    return
                }
                var first = true
                for try await _ in stream {
                    guard !Task.isCancelled else { return }
                    if first, prepared {
                        first = false
                        await loadTask?.value
                        continue
                    }
                    first = false
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
                reload()
            }
        }
    }

    // MARK: - Loading

    /// Starts the initial listing now, before the screen is in a window,
    /// and returns once the first rows are applied, the load has ended
    /// without any, or `budget` has passed — whichever is first. The push
    /// then lands on content or on the loading status, never on content
    /// that arrives a moment after the wait did. The listing runs on
    /// regardless, and the subscription made on appearance spends its
    /// first hint on it rather than starting a second one.
    public private(set) var isPrepared = false

    public func prepare(within budget: TimeInterval) async {
        guard !isPrepared else { return }
        isPrepared = true
        loadViewIfNeeded()
        let startedAt = DispatchTime.now()
        if loadTask == nil {
            // Half the budget: what lands by then goes up together, and
            // the apply itself still fits inside the other half.
            firstApplyHeldUntil = startedAt + budget / 2
            startLoad()
            preparedLoadPending = true
        }
        guard !hasSettled else { return }
        _ = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                await self?.waitUntilSettled()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        // `settle()` sets this before it wakes anyone, so it is the answer
        // whichever child spoke first — and a cancelled wait is not a yes.
        let settled = hasSettled
        firstApplyHeldUntil = nil
        // The budget ran out with rows in hand: they go up now, so the push
        // lands on them, and the rest follow at the streaming pace.
        if !settled, lastApplyAt == nil, !pendingRows.isEmpty, loadTask != nil {
            await applyPendingRows(animated: false)
        }
        if FilaLog.isEnabled(.verbose) {
            FilaLog.verbose(
                "list \(traceName): prepared rows=\(visible.count) pending=\(pendingRows.count)"
                    + (settled ? " in " : " budget spent at ") + "\(milliseconds(since: startedAt))ms"
                    + " window=\(viewIfLoaded?.window != nil)"
            )
        }
    }

    /// Suspends until `settle()`. Cancellation — the budget ran out —
    /// resumes at once rather than holding the group open.
    private func waitUntilSettled() async {
        guard !hasSettled else { return }
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasSettled || Task.isCancelled {
                    continuation.resume()
                } else {
                    settledWaiters[ticket] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.settledWaiters.removeValue(forKey: ticket)?.resume() }
        }
    }

    private func settle() {
        hasSettled = true
        let waiters = settledWaiters
        settledWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Lists again. On screen only: a retained tab reloads when it appears,
    /// without competing with the one the user is viewing.
    public func reload() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self else { return }
        guard !holdsReloads else {
            reloadWasHeld = true
            return
        }
        firstApplyHeldUntil = nil
        startLoad()
    }

    private func startLoad() {
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
        pendingRows = []
        lastApplyAt = nil
        applyRowLimit = BackendListPacing.initialRowLimit
        loadTask = Task { [weak self] in
            guard let self else { return }
            var received = 0
            var truncated = false
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
                    // Only the latest reload owns the rows. During a refresh,
                    // a partial listing must not remove later pages.
                    guard !Task.isCancelled else { return }
                    if traces {
                        batches += 1
                        FilaLog.verbose(
                            "list \(traceName): batch \(batches) n=\(batch.count)"
                                + " wait=\(milliseconds(since: requestedAt))ms"
                        )
                    }
                    let remaining = limit - received
                    pendingRows.append(contentsOf: batch.prefix(remaining))
                    received += min(remaining, batch.count)
                    if batch.count > remaining {
                        truncated = true
                        break
                    }
                    guard !keepsContent else { continue }
                    // The first rows go up as soon as no push is holding
                    // them — they are what it waits for. After that one
                    // apply per interval: a diff costs by the row count,
                    // so a huge folder gets rarer applies rather than more
                    // of them.
                    if let lastApplyAt {
                        if DispatchTime.now() < lastApplyAt + BackendListPacing.applyInterval { continue }
                    } else if let held = firstApplyHeldUntil, DispatchTime.now() < held {
                        continue
                    }
                    await applyPendingRows(animated: animatesArrival)
                    guard !Task.isCancelled else { return }
                }
                guard !Task.isCancelled else { return }
                isTruncated = truncated
                if keepsContent {
                    items = pendingRows
                    pendingRows = []
                } else {
                    // What is still waiting goes up in bounded applies, the
                    // last of them the final one below.
                    while pendingRows.count > applyRowLimit {
                        await applyPendingRows(animated: animatesArrival)
                        guard !Task.isCancelled else { return }
                    }
                    items.append(contentsOf: pendingRows)
                    pendingRows = []
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
            await applyArranged(animated: keepsContent || animatesArrival, awaitingCompletion: true)
            guard !Task.isCancelled else { return }
            settle()
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

    /// One streaming apply: up to `applyRowLimit` of the waiting rows join
    /// `items` and go up; rows on screen settle a waiting push.
    private func applyPendingRows(animated: Bool) async {
        let take = min(pendingRows.count, applyRowLimit)
        items.append(contentsOf: pendingRows.prefix(take))
        pendingRows.removeFirst(take)
        lastApplyAt = .now()
        let cost = await applyArranged(animated: animated)
        // Tuned on screen only: an apply with no cells to make says
        // nothing about the ones that follow the push.
        if let cost, viewIfLoaded?.window != nil {
            applyRowLimit = BackendListPacing.rowLimit(after: take, costing: cost)
        }
        if !visible.isEmpty {
            settle()
        }
    }

    /// Rows landing on a screen that is up with nothing shown yet — the
    /// push went ahead of them — replace the status with a transition.
    /// Rows applied before the push, or added under rows already there,
    /// simply appear.
    private var animatesArrival: Bool {
        viewIfLoaded?.window != nil && visible.isEmpty
    }

    /// A load's apply: arranged off the main thread when the subclass can
    /// say how, on it otherwise, and shown when the arrangement is current.
    /// A streaming apply returns as soon as the rows are handed over — an
    /// animated arrival must not hold the next batch back for the length
    /// of its animation — while the final one waits for the collection
    /// view to finish, so what follows it finds the rows in place.
    /// Returns what the apply cost the main thread, or nil when nothing was
    /// applied — an arrangement that was overtaken — so the pacing has
    /// nothing to learn from.
    @discardableResult
    private func applyArranged(animated: Bool, awaitingCompletion: Bool = false) async -> TimeInterval? {
        guard let arranger = arranger() else {
            // On the main thread throughout, so the whole of it is the cost.
            let startedAt = DispatchTime.now()
            if awaitingCompletion {
                await withCheckedContinuation { continuation in
                    applySnapshot(animated: animated) { continuation.resume() }
                }
            } else {
                applySnapshot(animated: animated)
            }
            return max(0, Double(appliedAt.uptimeNanoseconds) - Double(startedAt.uptimeNanoseconds)) / 1_000_000_000
        }
        applyGeneration += 1
        let generation = applyGeneration
        let traces = FilaLog.isEnabled(.verbose)
        let startedAt = DispatchTime.now()
        let snapshot = items
        let arranged = await Task.detached(priority: .userInitiated) { arranger(snapshot) }.value
        // Something applied meanwhile — a sort change, say — over items
        // that already included these; this arrangement is the older one.
        guard !Task.isCancelled, generation == applyGeneration else { return nil }
        let arrangedAt = DispatchTime.now()
        if awaitingCompletion {
            await withCheckedContinuation { continuation in
                show(arranged, animated: animated, reloadingData: false) { continuation.resume() }
            }
        } else {
            show(arranged, animated: animated, reloadingData: false, completion: nil)
        }
        if traces {
            FilaLog.verbose(
                "list \(traceName): apply rows=\(arranged.count) of \(snapshot.count)"
                    + " arrange=\(milliseconds(since: startedAt, until: arrangedAt))ms off main "
                    + (animated ? "diff" : "apply") + "=\(milliseconds(since: arrangedAt, until: appliedAt))ms"
                    + " hooks=\(milliseconds(since: appliedAt, until: hookedAt))ms" + (animated ? " animated" : "")
                    + (awaitingCompletion ? " settled=\(milliseconds(since: hookedAt))ms" : "")
                    + (viewIfLoaded?.window == nil ? " off window" : "")
            )
        }
        return max(0, Double(appliedAt.uptimeNanoseconds) - Double(arrangedAt.uptimeNanoseconds)) / 1_000_000_000
    }

    /// Applies `arrange(items)` as the list's one section, then the status
    /// panel behind it. `reloadingData` redraws every row from scratch
    /// instead of diffing: `apply` with an identical snapshot is an empty
    /// diff that never asks the cell provider for anything, so a layout or
    /// unit change that leaves the items alone needs the reload.
    public func applySnapshot(animated: Bool, reloadingData: Bool = false, completion: (() -> Void)? = nil) {
        guard dataSource != nil else {
            completion?()
            return
        }
        applyGeneration += 1
        let traces = FilaLog.isEnabled(.verbose)
        let startedAt = DispatchTime.now()
        let arranged = arrange(items)
        let arrangedAt = DispatchTime.now()
        show(arranged, animated: animated, reloadingData: reloadingData, completion: completion)
        if traces {
            FilaLog.verbose(
                "list \(traceName): apply rows=\(arranged.count) of \(items.count)"
                    + " arrange=\(milliseconds(since: startedAt, until: arrangedAt))ms "
                    + (animated && !reloadingData ? "diff" : "apply") + "=\(milliseconds(since: arrangedAt, until: appliedAt))ms"
                    + " hooks=\(milliseconds(since: appliedAt, until: hookedAt))ms"
                    + (reloadingData ? " reload" : animated ? " animated" : "")
            )
        }
    }

    /// The one place rows reach the collection view.
    private func show(_ arranged: [Item], animated: Bool, reloadingData: Bool, completion: (() -> Void)?) {
        visible = arranged
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(arranged)
        if reloadingData {
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        } else {
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        appliedAt = .now()
        collectionView.showStatus(statusContent) { [weak self] in self?.statusAction() }
        snapshotDidApply()
        hookedAt = .now()
    }

    /// When the last apply handed its rows over, and when the status panel
    /// and `snapshotDidApply` were done with it: the trace tells the three
    /// apart, and an animated apply's completion — the animation's length,
    /// not the main thread's — is reported on its own.
    private var appliedAt = DispatchTime.now()
    private var hookedAt = DispatchTime.now()

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

/// The numbers behind a load's streaming applies.
enum BackendListPacing {
    /// The least time between two streaming applies after the first:
    /// room for frames between one apply's main-thread cost and the next.
    static let applyInterval: TimeInterval = 0.12
    /// New rows per apply before anything has been measured. The first
    /// apply on screen also makes its cells, which is most of its cost, so
    /// this starts under what a later apply can carry.
    static let initialRowLimit = 4000
    static let minimumRowLimit = 1000
    static let maximumRowLimit = 20000
    /// What one apply should cost the main thread: under the budget a
    /// push waits for, with room for the frame around it.
    static let applyTarget: TimeInterval = 0.04

    /// The next chunk, from what the last one cost: scaled toward the
    /// target, and never by more than a factor of four at once.
    static func rowLimit(after rows: Int, costing seconds: TimeInterval) -> Int {
        guard rows > 0, seconds > 0.001 else { return maximumRowLimit }
        let scaled = Double(rows) * min(4, max(0.25, applyTarget / seconds))
        return min(maximumRowLimit, max(minimumRowLimit, Int(scaled)))
    }
}

/// Wall-clock milliseconds between two marks, to one decimal, for the trace.
private func milliseconds(since start: DispatchTime, until end: DispatchTime = .now()) -> String {
    String(format: "%.1f", max(0, Double(end.uptimeNanoseconds) - Double(start.uptimeNanoseconds)) / 1_000_000)
}
#endif
