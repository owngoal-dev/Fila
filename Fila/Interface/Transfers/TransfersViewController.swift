import Combine
import SnapKit
import Then
import UIKit

/// What is running and what recently happened.
///
/// A plain controller with no opinion about how it is shown: it works pushed
/// onto a navigation stack, presented in a sheet, or installed as a tab's root,
/// and it does not carry a navigation controller of its own. `presentAsSheet()`
/// is one caller's choice, not the screen's.
///
/// The item identifier is the operation's `id` and not the operation itself.
/// That is what makes a running copy cheap: the identifiers do not change while
/// it runs, so every progress tick is a `reconfigureItems` of the rows that are
/// on screen rather than a diff of the whole list.
final class TransfersViewController: UIViewController {
    private enum Section: Int {
        case running
        case settled
    }

    private let center: OperationCenter
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!
    private var observation: AnyCancellable?
    private lazy var clearItem = UIBarButtonItem(
        image: UIImage(named: "broom"),
        primaryAction: UIAction { [weak self] _ in
            self?.center.clearFinished()
        }
    ).then {
        $0.accessibilityLabel = String(localized: "Clear")
    }

    init(center: OperationCenter) {
        self.center = center
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Tasks")
        clearItem.isEnabled = center.operations.contains { !$0.isRunning }
        navigationItem.rightBarButtonItem = clearItem
    }

    convenience init() {
        self.init(center: FileSession.shared.operations)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped).with {
            $0.headerMode = .supplementary
            $0.footerMode = .supplementary
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        buildDataSource()
        apply()

        // `@Published` on the center: the list follows the model rather than
        // being pushed at by every call site that starts a job.
        //
        // `receive(on:)` and not a bare sink: `@Published` fires on *will*Set,
        // so a sink reading `center.operations` reads the array from before the
        // change. Hopping to the next main-queue turn is what makes it the one
        // after.
        observation = center.$operations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
    }

    // MARK: - Content

    private func buildDataSource() {
        let cell = UICollectionView.CellRegistration<TransferCell, UUID> { [weak self] cell, _, id in
            guard let self, let operation = self.center.operations.first(where: { $0.id == id }) else { return }
            cell.configure(operation, center: self.center)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedHeader()
            let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            content.text = section == .running
                ? String(localized: "In Progress")
                : String(localized: "Recent")
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            // The honest part. `filad` runs a job for the connection that asked
            // for it and cancels every one of a peer's jobs when the peer goes
            // away, so this is not a background queue and must not look like one.
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .running
                ? String(localized: "Tasks stop if you close Fila.")
                : nil
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, id in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collection, kind, indexPath in
            switch kind {
            case UICollectionView.elementKindSectionHeader:
                return collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            default:
                return collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
            }
        }
    }

    private func apply() {
        let running = center.operations.filter(\.isRunning).map(\.id)
        let settled = center.operations.filter { !$0.isRunning }.map(\.id)
        clearItem.isEnabled = !settled.isEmpty

        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        if !running.isEmpty {
            snapshot.appendSections([.running])
            snapshot.appendItems(running, toSection: .running)
        }
        if !settled.isEmpty {
            snapshot.appendSections([.settled])
            snapshot.appendItems(settled, toSection: .settled)
        }

        dataSource.apply(snapshot, animatingDifferences: true)
        // The identifiers a progress tick produces are the ones already on
        // screen, so the apply above was an empty diff and nothing was redrawn.
        // The reconfigure is what actually moves the bar. It runs
        // unconditionally because "did anything change" is a comparison of two
        // whole snapshots, and there are never more than a handful of rows.
        if !snapshot.itemIdentifiers.isEmpty {
            var reconfigured = snapshot
            reconfigured.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(reconfigured, animatingDifferences: false)
        }

        collectionView.showStatus(center.operations.isEmpty
            ? .message(
                symbol: "tray.and.arrow.down.fill",
                title: String(localized: "No Tasks"),
                detail: String(localized: "Copy, move, delete, and other tasks appear here.")
            )
            : nil)
    }

    /// Where a toast's *Details* goes. Wrapped and presented here rather than
    /// by the screen itself, so the screen stays usable anywhere else.
    static func presentAsSheet() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController else { return }

        var top = root
        while let presented = top.presentedViewController { top = presented }
        // A second failure while the list is already up must not stack another
        // copy of it on top of the first.
        if let navigation = top as? UINavigationController,
           navigation.viewControllers.contains(where: { $0 is TransfersViewController }) { return }

        let controller = TransfersViewController()
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
            menu: nil
        )
        controller.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
        top.presentAsSheet(navigation)
    }
}

extension TransfersViewController: UICollectionViewDelegate {
    /// A transfer is not a destination. Everything a row can do — undo, cancel
    /// — is a button on the row.
    func collectionView(_: UICollectionView, shouldSelectItemAt _: IndexPath) -> Bool { false }
}
