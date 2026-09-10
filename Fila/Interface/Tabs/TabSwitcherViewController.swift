import FilaBackendKit
import AlertController
import FilaBackendUI
import SnapKit
import Then
import UIKit

/// The content overview shows the last visible frame of each live tab.
final class TabSwitcherViewController: UIViewController {
    private weak var content: TabContainerViewController?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

    /// A tab kept out of the grid until `revealDeferred()`, so that a tab
    /// opened from a menu can be seen arriving rather than already there.
    private var deferred: UUID?
    /// Cards whose first display is an arrival, and get the blur-in.
    private var entering: Set<UUID> = []

    /// The highlighted card: the tab this window shows, which another
    /// window's selection does not change.
    private var currentTabID: UUID? {
        content?.installedTabID ?? BrowserTabStore.shared.currentID
    }

    init(content: TabContainerViewController, deferring: UUID? = nil) {
        self.content = content
        deferred = deferring
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Tabs")
        navigationItem.largeTitleDisplayMode = .never
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Tabs")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout()).then {
            $0.backgroundColor = .clear
            $0.delegate = self
            $0.alwaysBounceVertical = true
        }
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        buildDataSource()
        apply(animated: false)
        collectionView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reorder(_:))))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tabsChanged),
            name: .filaTabsChanged,
            object: nil
        )
    }

    private static func makeLayout() -> UICollectionViewLayout {
        TabGridLayout { _, environment in
            let inset = FilaUI.Spacing.large
            let spacing = FilaUI.Spacing.medium
            let width = max(1, environment.container.effectiveContentSize.width - 2 * inset)
            let minimum: CGFloat = environment.traitCollection.preferredContentSizeCategory
                .isAccessibilityCategory ? 280 : 160
            let columns = max(1, Int((width + spacing) / (minimum + spacing)))
            let item = NSCollectionLayoutItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(230))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(230)),
                subitem: item,
                count: columns
            )
            group.interItemSpacing = .fixed(spacing)
            return NSCollectionLayoutSection(group: group).then {
                $0.interGroupSpacing = spacing
                $0.contentInsets = .init(top: inset, leading: inset, bottom: inset, trailing: inset)
            }
        }
    }

    private func buildDataSource() {
        let card = UICollectionView.CellRegistration<TabCardCell, UUID> { [weak self] cell, _, id in
            guard let self, let tab = BrowserTabStore.shared.tabs.first(where: { $0.id == id }) else { return }
            let preview = content?.preview(for: tab)
            cell.configure(
                title: preview?.title ?? tab.title,
                path: tab.path,
                image: preview?.image,
                current: id == currentTabID
            ) { [weak self] in self?.shell?.closeTab(id) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, id in
            collection.dequeueConfiguredReusableCell(using: card, for: indexPath, item: id)
        }
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { transaction in
            BrowserTabStore.shared.reorder(to: transaction.finalSnapshot.itemIdentifiers)
        }
    }

    private func buildBars() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in
                // Closing without choosing lands back on this window's page.
                self?.content?.showInstalledTab()
            }
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
        // A new tab starts somewhere chosen: the plus offers the same folders
        // the sidebar does, and the tab opens and is shown at once.
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] complete in complete(self?.newTabMenuElements() ?? []) },
        ]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "New Tab")
        updateToolbar(sidebarVisible: false)
    }

    func updateToolbar(sidebarVisible: Bool) {
        let closeAll = UIBarButtonItem(title: String(localized: "Close All"), primaryAction: UIAction { [weak self] _ in
            self?.confirmCloseAll()
        })
        closeAll.tintColor = .systemRed
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in
                self?.shell?.presentSettings()
            }
        ).then {
            $0.accessibilityLabel = String(localized: "Settings")
        }
        let places = UIBarButtonItem(image: UIImage(systemName: "bookmark"), primaryAction: UIAction { [weak self] _ in
            self?.shell?.presentSidebar(settingsShown: false)
        }).then {
            $0.accessibilityLabel = String(localized: "Places")
        }
        if #available(iOS 26.0, *) {
            settings.sharesBackground = false
            closeAll.sharesBackground = false
            places.sharesBackground = false
        }
        toolbarItems = sidebarVisible ? [.flexibleSpace(), closeAll, .flexibleSpace()] : [
            .flexibleSpace(), settings, .fixedSpace(FilaUI.Spacing.medium),
            closeAll, .fixedSpace(FilaUI.Spacing.medium), places, .flexibleSpace(),
        ]
    }

    /// The bar button sits where a thumb rests during one-handed browsing, so
    /// more than one tab asks first. A lone tab closes without ceremony.
    private func confirmCloseAll() {
        guard BrowserTabStore.shared.tabs.count > 1 else {
            shell?.closeAllTabs()
            return
        }
        let alert = AlertViewController(
            title: String(localized: "Close All Tabs?"),
            message: String(localized: "Every open tab will close; tabs with unsaved changes will ask first.")
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Close All"), attribute: .accent) {
                context.dispose { self.shell?.closeAllTabs() }
            }
        }
        present(alert, animated: true)
    }

    private func newTabMenuElements() -> [UIMenuElement] {
        let full = BrowserTabStore.shared.isFull
        func open(_ path: String, title: String, image: UIImage?, subtitle: String? = nil) -> UIAction {
            UIAction(
                title: title,
                subtitle: subtitle,
                image: image,
                attributes: full ? .disabled : []
            ) { [weak self] _ in
                self?.shell?.openInNewTab(path)
            }
        }
        let places = SidebarLocation.orderedDestinations.map { destination -> UIMenuElement in
            switch destination {
            case let .directory(place):
                return open(place.path, title: place.title, image: FilaMenu.preview(for: place))
            case let .catalog(root):
                return UIAction(
                    title: root.displayName,
                    image: SidebarLocation.image(for: root),
                    attributes: full ? .disabled : []
                ) { [weak self] _ in
                    self?.shell?.openInNewTab(location: root.location)
                }
            }
        }
        return [UIMenu(title: String(localized: "Places"), options: .displayInline, children: places)]
            + FilaMenu.collections(attributes: full ? .disabled : []) { [weak self] path in
                self?.shell?.openInNewTab(path)
            }
    }

    static let cardCornerRadius = FilaUI.Spacing.large

    /// The card thumbnail's height over width. `TabCardCell` sizes its image
    /// view with it, and the container crops both the capture and the zoom
    /// window to it, so a page shrinks onto exactly the pixels the thumbnail
    /// shows of it.
    static let thumbnailAspect: CGFloat = 0.85

    /// The largest `thumbnailAspect` rectangle inside `bounds`, anchored to
    /// its top and leading edges: the region of the page a card's thumbnail
    /// displays of it. Leading rather than centred because the safe-area rect
    /// is horizontally asymmetric exactly where something sits beside the
    /// page — a sidebar column on one side, a home-indicator inset on the
    /// other — and landscape constrains the height, so a centred crop there
    /// starts mid-content and reads as the preview sitting offset.
    static func thumbnailRegion(in bounds: CGRect) -> CGRect {
        var width = bounds.width
        var height = width * thumbnailAspect
        if height > bounds.height {
            height = bounds.height
            width = height / thumbnailAspect
        }
        return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: height)
    }

    /// The frame of the card's page thumbnail — not the whole card, whose
    /// header sits above it — in `target`'s coordinates, for the container's
    /// zoom. Nil when the card is off screen — or, with `scrollingIntoView`,
    /// when a non-animated scroll still cannot show it.
    func cardFrame(for id: UUID, in target: UIView, scrollingIntoView: Bool) -> CGRect? {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return nil }
        var visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        if scrollingIntoView, !visible.contains(frame) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        }
        guard visible.intersects(frame),
              let cell = collectionView.cellForItem(at: indexPath) as? TabCardCell else { return nil }
        cell.layoutIfNeeded()
        return cell.convert(cell.previewFrame, to: target)
    }

    @objc private func tabsChanged() {
        apply(animated: true)
    }

    /// Lets the deferred tab into the grid, arriving like any other new card.
    func revealDeferred() {
        deferred = nil
        apply(animated: true)
    }

    /// A card arrives or leaves the way a SwiftUI `.scale(0.95)` combined with
    /// opacity and blur would: the layout scales and fades it, the cell blurs.
    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(BrowserTabStore.shared.tabs.map(\.id).filter { $0 != deferred })
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let arriving = Set(snapshot.itemIdentifiers)
        // Structural changes leave surviving thumbnails untouched. Only the
        // selection border can change while this overview stays on screen.
        let current = currentTabID
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath), arriving.contains(id) else { continue }
            (cell as? TabCardCell)?.setCurrent(id == current)
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            entering.formUnion(arriving.subtracting(existing))
            for id in existing.subtracting(arriving) {
                guard let indexPath = dataSource.indexPath(for: id) else { continue }
                (collectionView.cellForItem(at: indexPath) as? TabCardCell)?.veil(true)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    @objc private func reorder(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(
                at: gesture.location(in: collectionView)
            ) else { return }
            collectionView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(gesture.location(in: collectionView))
        case .ended:
            collectionView.endInteractiveMovement()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }
}

extension TabSwitcherViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        shell?.selectTab(id)
    }

    func collectionView(_: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), entering.remove(id) != nil else { return }
        (cell as? TabCardCell)?.veil(false)
    }
}

/// Inserted cards scale up from 0.95 as they fade in; removed ones shrink and
/// fade out. Moves keep the layout's own slide, which is what a reorder wants.
private final class TabGridLayout: UICollectionViewCompositionalLayout {
    private var inserted: Set<IndexPath> = []
    private var deleted: Set<IndexPath> = []

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        for update in updateItems {
            switch update.updateAction {
            case .insert: update.indexPathAfterUpdate.map { _ = inserted.insert($0) }
            case .delete: update.indexPathBeforeUpdate.map { _ = deleted.insert($0) }
            default: break
            }
        }
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        inserted = []
        deleted = []
    }

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        if inserted.contains(itemIndexPath) {
            Self.recede(attributes)
        }
        return attributes
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        if deleted.contains(itemIndexPath) {
            Self.recede(attributes)
        }
        return attributes
    }

    private static func recede(_ attributes: UICollectionViewLayoutAttributes?) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        attributes?.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        attributes?.alpha = 0
    }
}

private final class TabCardCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private var onClose: (() -> Void)?

    /// Where the page thumbnail sits, in the cell's coordinates.
    var previewFrame: CGRect {
        imageView.convert(imageView.bounds, to: self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = TabSwitcherViewController.cardCornerRadius
        contentView.clipsToBounds = true

        // One line: the thumbnail already shows where the tab is, and a path
        // under every title was more to read than the grid could carry.
        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .headline)
            $0.adjustsFontForContentSizeCategory = true
            $0.lineBreakMode = .byTruncatingMiddle
        }
        closeButton.do {
            $0.setImage(UIImage(systemName: "xmark"), for: .normal)
            // The same text style as the title beside it, so the glyph reads
            // as part of the header line rather than a control floating over it.
            $0.setPreferredSymbolConfiguration(.init(textStyle: .headline), forImageIn: .normal)
            $0.tintColor = .secondaryLabel
            $0.addTarget(self, action: #selector(close), for: .touchUpInside)
        }
        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton]).then {
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.compact
            $0.isLayoutMarginsRelativeArrangement = true
            $0.directionalLayoutMargins = .init(
                top: FilaUI.Spacing.small,
                leading: FilaUI.Spacing.medium,
                bottom: FilaUI.Spacing.small,
                trailing: FilaUI.Spacing.compact
            )
        }

        imageView.do {
            $0.backgroundColor = .tertiarySystemGroupedBackground
            $0.tintColor = .tertiaryLabel
            $0.clipsToBounds = true
        }
        let stack = UIStackView(arrangedSubviews: [header, imageView])
        stack.axis = .vertical
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        imageView.snp.makeConstraints { make in
            make.height.equalTo(imageView.snp.width)
                .multipliedBy(TabSwitcherViewController.thumbnailAspect)
        }
        closeButton.snp.makeConstraints { make in
            make.size.equalTo(FilaUI.minimumTapTarget)
        }
        isAccessibilityElement = true
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Close Tab")) { [weak self] _ in
                self?.onClose?()
                return true
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    func configure(title: String, path: String, image: UIImage?, current: Bool, onClose: @escaping () -> Void) {
        titleLabel.text = title
        imageView.image = image ?? UIImage(systemName: "folder")
        imageView.contentMode = image == nil ? .center : .scaleAspectFill
        self.onClose = onClose
        accessibilityLabel = title + ", " + path
        setCurrent(current)
    }

    func setCurrent(_ current: Bool) {
        accessibilityValue = current ? String(localized: "Current Tab") : nil
        accessibilityTraits = current ? [.button, .selected] : [.button]
        updateBorder()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorder()
    }

    private func updateBorder() {
        let current = accessibilityTraits.contains(.selected)
        contentView.layer.borderWidth = current ? 2 : 1
        contentView.layer.borderColor = (current ? tintColor : UIColor.separator)
            .resolvedColor(with: traitCollection).cgColor
    }

    @objc private func close() {
        onClose?()
    }

    // MARK: - Arrival and departure

    /// The blur half of the card's transition; the layout does scale and fade.
    /// Hidden between transitions so the card costs nothing to draw.
    private lazy var veilView = UIVisualEffectView(effect: nil).then {
        $0.isUserInteractionEnabled = false
        $0.isHidden = true
        contentView.addSubview($0)
        $0.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    /// `true` blurs a card that is leaving; `false` clears one that has arrived.
    func veil(_ leaving: Bool) {
        let blur = UIBlurEffect(style: .systemThinMaterial)
        veilView.layer.removeAllAnimations()
        veilView.isHidden = false
        veilView.effect = leaving ? nil : blur
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.veilView.effect = leaving ? blur : nil
        } completion: { _ in
            if !leaving {
                self.veilView.isHidden = true
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        veilView.layer.removeAllAnimations()
        veilView.effect = nil
        veilView.isHidden = true
    }
}
