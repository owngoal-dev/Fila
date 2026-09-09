#if canImport(UIKit)
import SnapKit
import Then
import UIKit

/// A screen that lives in a tab, and the one layout its bars follow.
///
/// Top bar: Back and Places on the leading side, which the shell supplies
/// from the tab's stack and the split view's state; the title; the screen's
/// own actions trailing. Bottom bar: how the screen searches on the leading
/// side, where the screen is as a breadcrumb in the centre, and the Tabs
/// control trailing — the first two may be empty, and Tabs is never
/// anywhere else.
///
/// A screen fills slots and never assembles a bar. The base asks its
/// `decorationSource` for the breadcrumb, sizes it to the room the other
/// slots leave, and shows the Tabs control only once the shell has given
/// the screen its tab's `bar`: a sheet, a picker or a preview gets no Tabs
/// and, with nothing else set, no bottom bar. The shell's
/// `TabNavigationController` sets `bar` before the push starts, so the bar
/// is complete before UIKit renders the transition — and because every
/// page of a tab puts the same Search, breadcrumb and Tabs objects on it,
/// the transition finds them already there and leaves them standing.
///
/// The breadcrumb is the same control on every page. A folder shows its
/// path, a share its name and the folders under it, a catalogue its artwork
/// and title with the entry under it, a file the folder it is in and its
/// own name. Where that comes from, and what a tap on an earlier crumb
/// does, is the `TabContentDecorationSource`'s.
open class TabContentViewController: UIViewController {
    // MARK: - Navigation bar

    /// The screen's own actions, trailing in the navigation bar: usually
    /// one ellipsis menu, an editor's Save, or nothing. First is outermost,
    /// as `rightBarButtonItems` has it. The leading side stays the shell's;
    /// a mode that needs Cancel there sets `hidesBackButton` and
    /// `leftBarButtonItems` itself, and the shell keeps out of an editing
    /// screen's exit.
    public var trailingNavigationItems: [UIBarButtonItem] = [] {
        didSet {
            guard (navigationItem.rightBarButtonItems ?? []) != trailingNavigationItems else { return }
            navigationItem.rightBarButtonItems = trailingNavigationItems.isEmpty ? nil : trailingNavigationItems
        }
    }

    // MARK: - Toolbar

    /// Whether the bottom bar's leading slot holds the Search button, which
    /// calls `search()`. A screen with a `UISearchController` uses
    /// `installSearch(_:)` instead, and on iOS 26 the field's own placement
    /// item takes the slot.
    public var wantsSearchButton = false {
        didSet { applyToolbar(animated: false) }
    }

    /// What the Search button does. Nothing by default.
    open func search() {}

    /// Bottom bar, leading, when `installSearch(_:)` put the field's
    /// placement item there.
    private var searchPlacementItem: UIBarButtonItem? {
        didSet { applyToolbar(animated: false) }
    }

    /// Who says where this screen is. A screen that knows conforms and
    /// leaves this nil; a screen shown on behalf of something else — a
    /// terminal for a file, a viewer over a share's snapshot, a page about a
    /// part of another page — is given an object that knows. Never the
    /// screen itself: that is what nil means, without a cycle.
    public var decorationSource: (any TabContentDecorationSource)? {
        didSet { reloadDecoration() }
    }

    /// The breadcrumb as last read from the source; the last crumb is the
    /// screen itself. Empty draws nothing.
    public private(set) var crumbs: [PathBarView.Crumb] = []

    /// The tab's shared bar controls — set by the shell that put this
    /// screen in a tab, and by nothing else. Nil means the screen is not in
    /// a tab: no Tabs control, and its own Search and breadcrumb if it
    /// shows any.
    public var bar: TabContentBar? {
        didSet {
            reloadDecoration()
            applyToolbar(animated: false)
        }
    }

    /// The breadcrumb this screen draws in: the tab's, or its own outside
    /// a tab.
    public var pathBar: PathBarView {
        bar?.pathBar ?? ownPathBar
    }

    /// A mode that owns the whole bottom bar — selection, say. Nil restores
    /// the standard layout.
    public private(set) var toolbarOverride: [UIBarButtonItem]?

    // The fallbacks for a screen outside a tab: a sheet's browser still
    // shows its search and its breadcrumb, without Tabs.
    private lazy var ownSearchItem = UIBarButtonItem(
        systemItem: .search,
        primaryAction: UIAction { [weak self] _ in self?.search() }
    )

    private lazy var ownPathBar = PathBarView().then {
        $0.onSelect = { [weak self] crumb in self?.selectDecorationCrumb(crumb) }
    }

    private lazy var ownPathBarItem: UIBarButtonItem = {
        ownPathBar.snp.makeConstraints { make in
            ownPathBarWidth = make.width.equalTo(FilaUI.minimumTapTarget).constraint
            make.height.equalTo(FilaUI.minimumTapTarget)
        }
        return UIBarButtonItem(customView: ownPathBar)
    }()

    private var ownPathBarWidth: Constraint?
    private let ownLeadingSpace = UIBarButtonItem.flexibleSpace()
    private let ownTrailingSpace = UIBarButtonItem.flexibleSpace()

    override public init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    // MARK: - Slots

    /// The standard trailing action: an ellipsis over `menu`, labelled More.
    public static func actionsItem(menu: UIMenu?) -> UIBarButtonItem {
        UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu).then {
            $0.accessibilityLabel = String(localized: "More", bundle: .module)
        }
    }

    /// Installs the screen's search controller where the OS puts one: in
    /// the navigation bar, and on iOS 26 integrated into the bottom bar's
    /// leading slot, where the local browser's Search button is.
    public func installSearch(_ controller: UISearchController) {
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integrated
            searchPlacementItem = navigationItem.searchBarPlacementBarButtonItem
        }
    }

    /// Replaces the whole bottom bar with `items`, or restores the standard
    /// layout with nil. `animated` is honoured only where the animation is
    /// UIKit's glass transition and the bar is on screen to show it.
    public func setToolbarOverride(_ items: [UIBarButtonItem]?, animated: Bool) {
        toolbarOverride = items
        applyToolbar(animated: animated)
    }

    // MARK: - Decoration

    /// The source the breadcrumb reads: the given object, else the screen
    /// itself when it conforms, else nothing.
    private var effectiveDecorationSource: (any TabContentDecorationSource)? {
        decorationSource ?? (self as? any TabContentDecorationSource)
    }

    /// Reads the breadcrumb again. A screen calls this when what it would
    /// answer has changed — artwork arrived, a title was saved — the way a
    /// table reloads when its data source's answers change.
    public func reloadDecoration() {
        let read = effectiveDecorationSource?.decorationCrumbs(for: self) ?? []
        guard read != crumbs else { return }
        let wasShown = !crumbs.isEmpty
        crumbs = read
        if let bar {
            if bar.current === self {
                bar.pathBar.setCrumbs(crumbs)
            }
        } else {
            ownPathBar.setCrumbs(crumbs)
        }
        if wasShown != !crumbs.isEmpty {
            applyToolbar(animated: false)
        }
    }

    /// Routes a tap on an earlier crumb to the source. Public so a source
    /// standing in for another screen can hand a crumb it does not own back
    /// to that screen.
    public func selectDecorationCrumb(_ crumb: PathBarView.Crumb) {
        effectiveDecorationSource?.tabContent(self, didSelectDecorationCrumb: crumb)
    }

    /// The screen whose breadcrumb a page pushed from here continues: a
    /// viewer hosted inside a container has none of its own, the container
    /// has the file's.
    public var decorationOwner: TabContentViewController {
        (parent as? TabContentViewController) ?? self
    }

    /// Pushes `screen` as a page about a part of this one — a plist's nested
    /// dictionary, a Mach-O's entitlements, a file's flags — continuing this
    /// screen's breadcrumb with the page's title.
    public func pushDetail(_ screen: TabContentViewController, animated: Bool = true) {
        screen.decorationSource = DetailDecoration(parent: decorationOwner, title: screen.title ?? "")
        navigationController?.pushViewController(screen, animated: animated)
    }

    /// The tab's bar shows this page from the moment it starts appearing —
    /// a push, a pop, or a pop that was cancelled halfway — so the shared
    /// breadcrumb never shows the page that is leaving.
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadDecoration()
        bar?.adopt(self)
    }

    // MARK: - Composition

    private var standardToolbarItems: [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if let searchPlacementItem {
            items.append(searchPlacementItem)
        } else if wantsSearchButton {
            items.append(bar?.searchItem ?? ownSearchItem)
        }
        if !crumbs.isEmpty {
            items += [bar?.leadingSpace ?? ownLeadingSpace, bar?.pathBarItem ?? ownPathBarItem]
        }
        if let bar {
            items += [bar.trailingSpace, bar.tabsItem]
        } else if !crumbs.isEmpty {
            items.append(ownTrailingSpace)
        }
        return items
    }

    private func applyToolbar(animated: Bool) {
        let items = toolbarOverride ?? standardToolbarItems
        if (toolbarItems ?? []) != items {
            setToolbarItems(items, animated: canAnimateToolbar(animated))
        }
        viewIfLoaded?.setNeedsLayout()
        syncToolbarVisibility()
    }

    /// The bar is shown exactly when there is something on it. The tab's
    /// navigation delegate applies the same rule at every push and pop; this
    /// covers a change while the screen is already on top.
    private func syncToolbarVisibility() {
        guard let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil else { return }
        navigationController.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: false)
    }

    private func canAnimateToolbar(_ requested: Bool) -> Bool {
        if #available(iOS 26.0, *) {
            return requested && !UIAccessibility.isReduceMotionEnabled
                && viewIfLoaded?.window != nil
                && navigationController?.topViewController === self
                && navigationController?.transitionCoordinator == nil
        }
        return false
    }

    // MARK: - The breadcrumb's width

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCenterWidth()
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pathBar.revealCurrentComponent()
    }

    private func updateCenterWidth() {
        guard !crumbs.isEmpty else { return }
        // Only the page the bar shows sizes the shared breadcrumb: the page
        // leaving lays out too, in the same column, and must not fight.
        if let bar, bar.current !== self { return }
        guard let width = bar?.pathBarWidth ?? ownPathBarWidth else { return }
        // Reserve native control widths, outer margins and inter-group gaps.
        // Measure this content column, never the screen or the split sidebar.
        let available = view.safeAreaLayoutGuide.layoutFrame.width
        let slot = FilaUI.minimumTapTarget + FilaUI.Spacing.large + FilaUI.Spacing.small
        var reserved = 2 * FilaUI.Spacing.large
        if searchPlacementItem != nil || wantsSearchButton {
            reserved += slot
        }
        if bar != nil {
            reserved += slot
        }
        let target = max(FilaUI.minimumTapTarget, available - reserved)
        if abs((width.layoutConstraints.first?.constant ?? 0) - target) > 0.5 {
            width.update(offset: target)
        }
    }
}
#endif
