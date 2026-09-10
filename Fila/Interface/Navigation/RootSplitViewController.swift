import FilaBackendKit
import FilaBackendUI
import Then
import UIKit

/// The shell: a tab, and — on an iPad — a sidebar beside it.
///
/// The home screen is the tab's content. There is no third column any more:
/// a viewer, an editor or a terminal fills the tab it was opened from rather
/// than living in a panel beside it, which is what makes "a tab" mean the same
/// thing on a phone and on an iPad.
///
/// Two columns, and a third view controller for the collapsed shape. Setting
/// one for `.compact` is what stops UIKit merging the sidebar into the phone's
/// navigation stack: on a phone the sidebar is not a column that happens to be
/// off screen, it is a sheet, and the browser is the root of the app rather
/// than something you reach past a list of places.
final class RootSplitViewController: UISplitViewController {
    /// The primary column, and only ever that. A phone reaches the same rows
    /// through `presentSidebar()`.
    let sidebar = SidebarViewController()

    /// One runtime owner moves intact between the split view's column hosts.
    /// A size-class change never dismantles a tab's navigation subtree.
    let content = TabContainerViewController()
    private let wideContent = UIViewController()
    private let compactContent = UIViewController()

    init() {
        super.init(style: .doubleColumn)
        content.owner = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        setViewController(UINavigationController(rootViewController: sidebar), for: .primary)
        // Split view wraps a plain secondary controller in a navigation
        // controller. Supply both column wrappers with their bars hidden;
        // the live tab is the only owner of visible navigation chrome.
        let wideNavigation = UINavigationController(rootViewController: wideContent)
        wideNavigation.setNavigationBarHidden(true, animated: false)
        setViewController(wideNavigation, for: .secondary)
        let compactNavigation = UINavigationController(rootViewController: compactContent)
        compactNavigation.setNavigationBarHidden(true, animated: false)
        setViewController(compactNavigation, for: .compact)

        // The handshake is started here rather than lazily by the first
        // request: `filad` is on-demand, and asking early means the daemon is
        // usually up by the time the first directory is asked for.
        Task { await FileSession.shared.ready() }
    }

    /// `isCollapsed` is only true once UIKit has laid the split view out, so
    /// the tab is installed here rather than in `viewDidLoad` — where it would
    /// go into the wrong column on a phone and have to be moved a moment later,
    /// listing the same directory twice.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncContentColumn()
    }

    // MARK: - The tab

    /// Moves the content owner, including an open overview and every retained
    /// tab, into the visible column. The navigation controllers stay parented.
    private func syncContentColumn() {
        content.move(to: isCollapsed ? compactContent : wideContent)
        if content.navigation == nil {
            content.showCurrentTab()
        }
        content.refreshSidebarButton()
    }

    /// Our own items rather than `displayModeButtonItem`: UIKit already shows
    /// that one in the primary column. One item per bar, because a bar button
    /// item has one view and UIKit's animated item swap fades that view — an
    /// item shared between two bars would have nothing left to fade out of the
    /// first while it fades into the second.
    ///
    /// The same rule applies along the navigation stack: a push or pop renders
    /// the departing and arriving bars together, so an item taken off the
    /// departing screen in `willShow` left a blank capsule behind and faded
    /// in late on the arriving one. Every screen keeps its own pair, ready
    /// before the transition starts.
    private let sidebarToggles = NSMapTable<UIViewController, UIBarButtonItem>.weakToStrongObjects()
    private let navigationBacks = NSMapTable<UIViewController, UIBarButtonItem>.weakToStrongObjects()
    private lazy var columnToggle = makeSidebarToggle()

    private func item(
        in table: NSMapTable<UIViewController, UIBarButtonItem>,
        for controller: UIViewController,
        make: () -> UIBarButtonItem
    ) -> UIBarButtonItem {
        if let item = table.object(forKey: controller) {
            return item
        }
        let item = make()
        table.setObject(item, forKey: controller)
        return item
    }

    private func makeSidebarToggle() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "sidebar.leading"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if isCollapsed {
                    presentSidebar()
                } else if displayMode == .secondaryOnly {
                    show(.primary)
                } else {
                    hide(.primary)
                }
            }
        ).then {
            $0.accessibilityLabel = String(localized: "Places")
            if #available(iOS 26.0, *) {
                $0.identifier = "sidebar"
                $0.sharesBackground = false
            }
        }
    }


    /// A standard Back item preserves the guarded history menu while allowing
    /// the sidebar toggle to move between columns independently.
    private func makeNavigationBack() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            primaryAction: UIAction { [weak self] _ in
                self?.navigateBack()
            }
        ).then {
            $0.accessibilityLabel = String(localized: "Back")
            if #available(iOS 26.0, *) {
                $0.identifier = "back"
                $0.sharesBackground = false
            }
        }
    }

    private var announcedDisplayMode: UISplitViewController.DisplayMode?
    private var animateToggleTransfer = false

    func configureSidebarButton(for controller: UIViewController, leadingItems: [UIBarButtonItem]? = nil) {
        guard controller === content.visibleTop, let navigation = controller.navigationController,
              let index = navigation.viewControllers.firstIndex(of: controller) else { return }
        prepareNavigationItems(
            for: controller,
            in: navigation,
            ancestors: Array(navigation.viewControllers.prefix(index)),
            leadingItems: leadingItems
        )
    }

    /// The destination need not be in the stack yet. The tab supplies its future
    /// ancestors before UIKit starts rendering the push or pop transition.
    func prepareNavigationItems(
        for controller: UIViewController,
        in navigation: UINavigationController,
        ancestors: [UIViewController],
        leadingItems: [UIBarButtonItem]? = nil
    ) {
        let item = controller.navigationItem
        let toggle = self.item(in: sidebarToggles, for: controller, make: makeSidebarToggle)
        let back = self.item(in: navigationBacks, for: controller, make: makeNavigationBack)
        let inSidebar = !isCollapsed && (announcedDisplayMode ?? displayMode) != .secondaryOnly
        (controller as? TabSwitcherViewController)?.updateToolbar(sidebarVisible: inSidebar)
        var buttons = (leadingItems ?? item.leftBarButtonItems ?? [])
            .filter { $0 !== toggle && $0 !== back }
        // An editor or selection mode owns its Cancel/guarded Back. Keep that
        // exit intact, rather than creating another route around its save guard.
        if !controller.isEditing, !item.hidesBackButton {
            if !ancestors.isEmpty, buttons.isEmpty {
                back.menu = UIMenu(children: ancestors.reversed().map { destination in
                    UIAction(
                        title: destination.navigationItem.title ?? destination.title ?? String(localized: "Back")
                    ) { [weak self, weak destination] _ in
                        guard let destination else { return }
                        self?.navigateBack(to: destination)
                    }
                })
                buttons.insert(back, at: 0)
            } else if ancestors.isEmpty, buttons.isEmpty,
                      let browser = controller as? FileBrowserViewController, browser.directory != "/"
            {
                back.menu = nil
                buttons.insert(back, at: 0)
            }
            // Custom leading items suppress UIKit's default Back control.
            // Keep its native edge transition, subject to editor guards.
            navigation.interactivePopGestureRecognizer?.delegate = self
            // On a phone, Places lives in the tab overview's bottom toolbar.
            // Wide layouts keep the control that restores the sidebar column.
            if !isCollapsed, !inSidebar {
                buttons.append(toggle)
            }
        }
        item.leftItemsSupplementBackButton = false
        // UIKit's animated item swap fades the arriving and departing buttons
        // alongside the column slide it was announced with.
        let animated = animateToggleTransfer && !UIAccessibility.isReduceMotionEnabled
        if (item.leftBarButtonItems ?? []) != buttons {
            item.setLeftBarButtonItems(buttons.isEmpty ? nil : buttons, animated: animated)
        }
        sidebar.setColumnToggle(inSidebar ? columnToggle : nil, animated: animated)
    }

    private func navigateBack(to requested: UIViewController? = nil) {
        guard let source = content.visibleTop,
              !source.isEditing, !source.navigationItem.hidesBackButton,
              let navigation = source.navigationController,
              navigation.transitionCoordinator == nil else { return }
        if navigation.viewControllers.count == 1 {
            guard requested == nil, let browser = source as? FileBrowserViewController,
                  browser.directory != "/" else { return }
            let parent = FileBrowserViewController(directory: (browser.directory as NSString).deletingLastPathComponent)
            navigation.setViewControllers([parent, source], animated: false)
            navigation.popViewController(animated: true)
            return
        }
        let destination = requested ?? navigation.viewControllers[navigation.viewControllers.count - 2]
        let perform = { [weak self, weak source, weak navigation, weak destination] in
            guard let self, let source, let navigation, let destination,
                  content.visibleTop === source,
                  navigation.topViewController === source,
                  navigation.viewControllers.contains(where: { $0 === destination }),
                  destination !== source else { return }
            navigation.popToViewController(destination, animated: true)
        }
        if let confirm = (source as? ViewerContainerViewController)?.confirmReplacement {
            confirm({}, perform)
        } else {
            perform()
        }
    }

    /// Re-roots the current tab at `path`, without retaining the old location.
    ///
    /// A jump and not a descent: this is what the sidebar's places, favorites
    /// and recents do, and going to `/etc` from `/var/mobile/Documents` is not
    /// something Back should walk out of through somebody's Documents. Back out
    /// of the jump climbs `/etc`'s own chain instead. Each parent is created
    /// only when Back opens it, so an unseen ancestor is never a recent visit.
    /// The compact column already hosts content. show(.secondary) while
    /// collapsed asks UIKit to push its navigation wrapper and crashes on iOS 18.
    func open(_ path: String, select: String? = nil) {
        confirmLeavingContent { [weak self] in
            guard let self else { return }
            dismissSidebarSheet()
            content.showRoot(path, select: select)
            if !isCollapsed {
                show(.secondary)
            }
        }
    }

    /// A folder named by a crumb on a screen that is not a browser — a
    /// viewer, a search, a terminal. Back to that folder's browser when it is
    /// on the stack, which it is after a descent; otherwise a jump to it,
    /// the way the sidebar's rows arrive.
    func showDirectory(_ path: String, from screen: UIViewController) {
        if let navigation = screen.navigationController,
           let browser = navigation.viewControllers.last(where: { ($0 as? FileBrowserViewController)?.directory == path })
        {
            navigation.popToViewController(browser, animated: true)
            return
        }
        open(path)
    }

    /// Pushes a screen into the current tab — a viewer, an editor, a search, a
    /// terminal. This is the only way anything gets in front of a tab, which is
    /// what makes "a tab can be covered by a preview" true without a second
    /// mechanism for each kind of cover.
    func push(_ viewController: UIViewController, animated: Bool = true) {
        confirmLeavingContent { [weak self] in
            self?.dismissSidebarSheet()
            self?.content.navigation?.pushViewController(viewController, animated: animated)
        }
    }

    /// Replaces the current tab's whole stack with `viewController`, with no
    /// transition. The sidebar's Applications entry is a jump like `open`, and
    /// a jump that pushed read as a descent from wherever the tab happened to be.
    func replace(_ viewController: UIViewController) {
        confirmLeavingContent { [weak self] in
            guard let self else { return }
            dismissSidebarSheet()
            content.navigation?.setViewControllers([viewController], animated: false)
            if !isCollapsed {
                show(.secondary)
            }
        }
    }

    /// Opens `path` in a new tab and shows it.
    ///
    /// At the cap it opens in *this* tab instead — the request was to see the
    /// folder, and refusing to navigate at all would read as the menu item
    /// being broken. Saying so is the toast's job. It goes through the browser
    /// that is on screen rather than pushing directly, so the folder arrives by
    /// the same rule as every other way of naming one: a child descends,
    /// anything else jumps. See `FileBrowserViewController.open(directory:)`.
    func openInNewTab(_ path: String) {
        content.captureCurrentTab()
        guard let tab = BrowserTabStore.shared.open(path) else {
            FeedbackAlert.show(
                String(localized: "Too Many Tabs"),
                message: String(localized: "This folder opened in the current tab. Close a tab to open a new one.")
            )
            confirmLeavingContent { [weak self] in
                guard let self else { return }
                if let browser = content.navigation?.topViewController as? FileBrowserViewController {
                    browser.open(directory: path)
                } else {
                    content.showRoot(path, select: nil)
                }
            }
            return
        }
        // A tour rather than a cut, so that opening in a new tab feels like
        // something happened: the page shrinks to its card, the new card
        // arrives beside it, and the new tab zooms out of that card. Reduce
        // Motion, or the overview already open, goes straight to the tab.
        guard !UIAccessibility.isReduceMotionEnabled, !content.isShowingOverview, view.window != nil else {
            content.showCurrentTab()
            return
        }
        content.showTabSwitcher(deferring: tab.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.content.revealDeferredTab()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.content.showCurrentTab() }
        }
    }

    /// A module's root screen in a new tab. The tab store records a
    /// directory per tab, so the catalogue tab restores to the current
    /// directory if the screen itself cannot be restored.
    func openInNewTab(location: BackendLocation) {
        guard let screen = SidebarLocation.screen(for: location) else { return }
        openInNewTab(screen, directory: FileSession.shared.lastDirectoryPath)
    }

    func openInNewTab(_ controller: UIViewController, directory: String) {
        guard !BrowserTabStore.shared.isFull else { return }
        content.captureCurrentTab()
        guard BrowserTabStore.shared.open(directory) != nil else { return }
        content.showCurrentTab(root: controller)
    }

    /// The `fila://open?path=…&tab=new` destination. `BrowserTabStore.openFromLink`
    /// decides *whether* a tab is made — it is capped and it deduplicates,
    /// because a link is an unauthenticated entry point — and this shows
    /// whatever it decided, so the link navigates either way.
    func openFromLink(_ path: String) {
        content.captureCurrentTab()
        BrowserTabStore.shared.openFromLink(path)
        content.showCurrentTab()
        if !isCollapsed {
            show(.secondary)
        }
    }

    /// The overview covers the content, without dismissing any document.
    func presentTabSwitcher() {
        content.showTabSwitcher()
    }

    func selectTab(_ id: UUID) {
        content.captureCurrentTab()
        BrowserTabStore.shared.select(id)
        content.showCurrentTab()
    }

    func closeTab(_ id: UUID) {
        closeTabs([id][...])
    }

    func closeAllTabs() {
        closeTabs(BrowserTabStore.shared.tabs.map(\.id)[...]) { [weak self] in
            guard let self else { return }
            BrowserTabStore.shared.closeAll()
            content.removeClosedTabs()
            content.showCurrentTab()
        }
    }

    /// Keep the overview and surviving previews installed while removing cards.
    /// Only an editor that actually needs a save/discard prompt becomes visible.
    private func closeTabs(_ ids: ArraySlice<UUID>, completion: (() -> Void)? = nil) {
        guard let id = ids.first else {
            if let completion { completion() } else { content.showTabSwitcher() }
            return
        }
        guard BrowserTabStore.shared.tabs.contains(where: { $0.id == id }) else {
            closeTabs(ids.dropFirst(), completion: completion)
            return
        }
        content.confirmClosingTab(id) { [weak self] in
            guard let self else { return }
            BrowserTabStore.shared.close(id)
            content.removeClosedTabs()
            closeTabs(ids.dropFirst(), completion: completion)
        }
    }

    /// Closing or replacing content consults the editor that owns its work.
    /// Merely switching to another retained tab does not discard anything.
    private func confirmLeavingContent(_ leave: @escaping () -> Void) {
        content.showCurrentTab()
        let navigation = content.navigation
        let source = navigation?.topViewController
        let viewer = navigation?.viewControllers.compactMap { $0 as? ViewerContainerViewController }.last
        let finish = { [weak self, weak navigation, weak source] in
            // Saving may finish after a tab switch. Its permission applies
            // only to the page that asked, never to a newly selected editor.
            guard let self, content.navigation === navigation,
                  navigation?.topViewController === source else { return }
            leave()
        }
        if let confirm = viewer?.confirmReplacement {
            confirm({}, finish)
        } else {
            leave()
        }
    }

    /// Called when the app goes away. The stack is already written down on
    /// every push and pop; this catches the scroll position, which moves
    /// continuously and is not worth a notification per pixel.
    func rememberState() {
        content.captureCurrentTab()
    }

    // MARK: - The sidebar

    /// A column on an iPad, a sheet on a phone.
    ///
    /// The phone gets a *second* `SidebarViewController` rather than the one in
    /// the primary column, because that one is inside the split view's own
    /// navigation controller and moving a view controller out of a container to
    /// present it and back again is a great deal of ceremony for a list that
    /// rebuilds itself from `UserDefaults` in a millisecond.
    func presentSidebar(settingsShown: Bool = true) {
        guard isCollapsed else {
            show(.primary)
            return
        }
        presentAsSheet(UINavigationController(rootViewController: SidebarViewController(settingsShown: settingsShown)))
    }

    /// The shell's own sheets — Places on a phone, Settings anywhere —
    /// give way when content is replaced beneath them: a server saved in
    /// Settings › Servers opens, and the sheet that added it is not left
    /// covering it. Any other presentation stays.
    private func dismissSidebarSheet() {
        let root = (presentedViewController as? UINavigationController)?.viewControllers.first
        guard root is SidebarViewController || root is SettingsViewController else { return }
        dismiss(animated: true)
    }
}

extension RootSplitViewController: UISplitViewControllerDelegate {
    func splitViewController(
        _: UISplitViewController,
        willChangeTo displayMode: UISplitViewController.DisplayMode
    ) {
        announcedDisplayMode = displayMode
        animateToggleTransfer = true
        content.refreshSidebarButton()
        animateToggleTransfer = false
    }

    func splitViewControllerDidCollapse(_: UISplitViewController) {
        syncContentColumn()
    }

    func splitViewControllerDidExpand(_: UISplitViewController) {
        syncContentColumn()
    }
}

extension RootSplitViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let top = content.visibleTop, let navigation = top.navigationController,
              gestureRecognizer === navigation.interactivePopGestureRecognizer,
              navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil,
              !top.isEditing, !top.navigationItem.hidesBackButton,
              !top.isModalInPresentation else { return false }
        return true
    }
}
