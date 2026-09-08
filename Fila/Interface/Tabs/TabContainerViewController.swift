import SnapKit
import Then
import UIKit

/// Live navigation belongs to this content container. BrowserTabStore persists only
/// directories; switching tabs never reconstructs an editor or its document.
final class TabContainerViewController: UIViewController {
    private struct Content {
        let navigation: UINavigationController
        var preview: UIImage?
    }

    private enum Appearance {
        case hidden, appearing, visible, disappearing
    }

    private var tabs: [UUID: Content] = [:]
    /// The tab whose navigation is installed, even while the overview covers it.
    private var installedTabID: UUID?
    private var displayed: UIViewController?
    private var appearance: Appearance = .hidden
    /// The zoom or crossfade between a tab and the overview, while it runs.
    private var transition: UIViewPropertyAnimator?
    /// False until the displayed child has had a run loop turn to reach the
    /// screen. Unsettled pages must not replace a previously captured preview.
    private var settled = false
    private var connectionTask: Task<Void, Never>?

    deinit { connectionTask?.cancel() }

    var navigation: UINavigationController? {
        installedTabID.flatMap { tabs[$0]?.navigation }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    /// The screen whose navigation item the visible bar reads: a tab's top, or
    /// the overview.
    var visibleTop: UIViewController? {
        (displayed as? UINavigationController)?.topViewController
    }

    func refreshSidebarButton() {
        guard let top = visibleTop else { return }
        // The initial child can be installed before it has a window. Its
        // containment already identifies the split view at that point.
        let owner = (splitViewController as? RootSplitViewController) ?? shell
        owner?.configureSidebarButton(for: top)
    }

    /// Move the whole owner between compact and wide hosts, preserving every
    /// navigation parent and an open overview. There is no second runtime map.
    func move(to host: UIViewController) {
        guard parent !== host else { return }
        finishTransition()
        if parent != nil {
            willMove(toParent: nil)
            view.removeFromSuperview()
            removeFromParent()
        }
        host.addChild(self)
        host.view.addSubview(view)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        didMove(toParent: host)
    }

    /// Hidden tabs remain children, but only the visible child gets appearance
    /// callbacks. Its navigation stack and first responder state stay separate.
    override var shouldAutomaticallyForwardAppearanceMethods: Bool {
        false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearance = .appearing
        displayed?.beginAppearanceTransition(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if appearance == .appearing {
            displayed?.endAppearanceTransition()
        }
        appearance = .visible
        refreshSidebarButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearance = .disappearing
        displayed?.beginAppearanceTransition(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if appearance == .disappearing {
            displayed?.endAppearanceTransition()
        }
        appearance = .hidden
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        finishTransition()
    }

    func showCurrentTab() {
        // Resolve the backend before constructing BrowserTabStore's first tab. A
        // sandboxed launch must start at Home, not persist an inaccessible /.
        guard FileSession.shared.hello != nil else {
            if connectionTask == nil {
                showConnecting()
                connectionTask = Task { [weak self] in
                    await FileSession.shared.ready()
                    guard !Task.isCancelled, let self else { return }
                    connectionTask = nil
                    showCurrentTab()
                }
            }
            return
        }
        let tab = BrowserTabStore.shared.current
        showTab(tab.id) { makeNavigation(Self.browsers(for: tab)) }
        removeClosedTabs()
    }

    func showCurrentTab(root: UIViewController) {
        showTab(BrowserTabStore.shared.currentID) { makeNavigation([root]) }
        removeClosedTabs()
    }

    private func makeNavigation(_ stack: [UIViewController]) -> TabNavigationController {
        let navigation = TabNavigationController()
        navigation.owner = shell
        navigation.setViewControllers(stack, animated: false)
        return navigation
    }

    /// Removing a background tab does not install, lay out or snapshot a survivor.
    func removeClosedTabs() {
        let remaining = Set(BrowserTabStore.shared.tabs.map(\.id))
        for id in tabs.keys.filter({ !remaining.contains($0) }) {
            guard let closed = tabs.removeValue(forKey: id)?.navigation else { continue }
            closed.willMove(toParent: nil)
            closed.viewIfLoaded?.removeFromSuperview()
            closed.removeFromParent()
            if installedTabID == id {
                installedTabID = nil
            }
        }
    }

    func confirmClosingTab(_ id: UUID, confirmed: @escaping () -> Void) {
        guard let navigation = tabs[id]?.navigation else { confirmed(); return }
        let viewer = navigation.viewControllers.compactMap { $0 as? ViewerContainerViewController }.last
        guard let confirm = viewer?.confirmReplacement else { confirmed(); return }
        let source = navigation.topViewController
        confirm({ [weak self] in
            self?.shell?.selectTab(id)
        }, { [weak self, weak navigation, weak source] in
            guard let self, let navigation, let source,
                  tabs[id]?.navigation === navigation,
                  navigation.topViewController === source else { return }
            // If a prompt displayed the editor, return to a settled overview
            // before removing it. Clean tabs never leave the existing overview.
            showTabSwitcher()
            confirmed()
        })
    }

    private func showConnecting() {
        // Keep navigation usable while launchd catches up. This temporary
        // screen is not a browser visit and never creates or persists a tab.
        let waiting = UIViewController()
        waiting.view.backgroundColor = .systemBackground
        let label = UILabel().then {
            $0.text = String(localized: "Connecting…")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
        }
        waiting.view.addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        // The shell supplies Places for this screen too, including when the
        // split view changes between compact and wide layouts.
        display(UINavigationController(rootViewController: waiting))
    }

    private static func browsers(for tab: BrowserTab) -> [UIViewController] {
        tab.stack.enumerated().map { index, path in
            let browser = BrowserViewController(
                directory: path,
                select: index == tab.stack.count - 1 ? tab.selection : nil
            )
            browser.restoredScrollOffset = tab.offsets[path]
            return browser
        }
    }

    /// One creation boundary, also usable by the Debug identity check without
    /// opening files. Existing tabs never invoke the factory again.
    private func showTab(_ id: UUID, makeNavigation: () -> UINavigationController) {
        if installedTabID != id {
            capturePreview()
        }
        if tabs[id] == nil {
            let navigation = makeNavigation()
            navigation.delegate = self
            tabs[id] = Content(navigation: navigation)
        }
        installedTabID = id
        if let navigation {
            display(navigation)
        }
    }

    /// A confirmed location jump intentionally replaces this tab's history:
    /// the destination becomes the tab's only page, with nothing to go back
    /// through the previous location. Back lazily opens the new path's parent;
    /// its other ancestors remain available in the path bar.
    func showRoot(_ path: String, select: String?) {
        BrowserTabStore.shared.record(stack: [path], offsets: [:], selection: select)
        if let id = installedTabID, let navigation {
            tabs[id]?.preview = nil
            navigation.setViewControllers(Self.browsers(for: BrowserTabStore.shared.current), animated: false)
        }
        showCurrentTab()
    }

    func captureCurrentTab() {
        guard installedTabID == BrowserTabStore.shared.currentID, let navigation else { return }
        let browsers = navigation.viewControllers.compactMap { $0 as? BrowserViewController }
        guard !browsers.isEmpty else { return }
        var offsets: [String: Double] = [:]
        for browser in browsers {
            offsets[browser.directory] = browser.scrollOffset
        }
        let top = browsers.last
        let selection = (top?.isViewLoaded ?? false) ? top?.selectedPaths().first : nil
        BrowserTabStore.shared.record(
            stack: browsers.map(\.directory),
            offsets: offsets,
            selection: selection.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    /// `deferring` keeps one tab out of the grid until `revealDeferredTab()`.
    func showTabSwitcher(deferring: UUID? = nil) {
        if overview(in: displayed) != nil {
            return
        }
        captureCurrentTab()
        capturePreview()
        let overview = UINavigationController(
            rootViewController: TabSwitcherViewController(content: self, deferring: deferring)
        )
        // Only the tab navigations have this container as their delegate, which
        // is what unhides a toolbar; the overview's Close All bar is unhidden here.
        overview.isToolbarHidden = false
        display(overview)
    }

    /// Whether the overview is what is on screen right now.
    var isShowingOverview: Bool {
        overview(in: displayed) != nil
    }

    func revealDeferredTab() {
        overview(in: displayed)?.revealDeferred()
    }

    func preview(for tab: BrowserTab) -> (title: String, image: UIImage?) {
        let content = tabs[tab.id]
        let top = content?.navigation.topViewController
        return (top?.navigationItem.title ?? top?.title ?? tab.title, content?.preview)
    }

    private func capturePreview() {
        guard settled, transition == nil, let id = installedTabID, let navigation, displayed === navigation,
              let surface = navigation.topViewController?.viewIfLoaded, surface.window != nil else { return }
        let bounds = surface.bounds.inset(by: surface.safeAreaInsets)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(1, 360 / bounds.width)
        let size = CGSize(width: bounds.width * scale, height: min(306, bounds.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drewContent = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            drewContent = surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: false)
        }
        if drewContent {
            tabs[id]?.preview = image
        }
    }

    private func display(_ next: UIViewController) {
        guard displayed !== next else { return }
        loadViewIfNeeded()
        finishTransition()
        let previous = displayed
        previous?.viewIfLoaded?.endEditing(true)
        let animate = prepareTransition(from: previous, to: next)
        let added = next.parent == nil
        if added {
            addChild(next)
        }
        // A child can be installed during the parent's first layout, between
        // will/didAppear. Finish the old child's transition before replacing it
        // and let didAppear complete the new child's matching begin.
        let appearing = appearance == .appearing
        let visible = appearing || appearance == .visible
        if appearing || appearance == .disappearing {
            previous?.endAppearanceTransition()
            if appearance == .disappearing {
                appearance = .hidden
            }
        }
        if visible {
            previous?.beginAppearanceTransition(false, animated: false)
            next.beginAppearanceTransition(true, animated: false)
        }
        previous?.viewIfLoaded?.removeFromSuperview()
        view.addSubview(next.view)
        next.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        displayed = next
        refreshSidebarButton()
        if added {
            next.didMove(toParent: self)
        }
        if visible {
            previous?.endAppearanceTransition()
            if !appearing {
                next.endAppearanceTransition()
            }
        }
        // An overview is disposable; inactive tab navigation stays parented so
        // disappearing does not mean the terminal or editor was closed.
        if let previous, !tabs.values.contains(where: { $0.navigation === previous }) {
            previous.willMove(toParent: nil)
            previous.removeFromParent()
        }
        settled = false
        DispatchQueue.main.async { [weak self] in self?.settled = true }
        animate?()
    }

    // MARK: - Overview transition

    private func overview(in controller: UIViewController?) -> TabSwitcherViewController? {
        (controller as? UINavigationController)?.viewControllers.first as? TabSwitcherViewController
    }

    /// Measures and snapshots before `display` swaps the children, and returns
    /// the animation to start after it; nil is the plain cut. Only a tab and the
    /// overview zoom into each other, and only when the outgoing view is on
    /// screen. The swap itself is unchanged: appearance callbacks, the sidebar
    /// button and parenting all happen synchronously, and the overlays here
    /// are cosmetic — a snapshot of whichever side is leaving and a mask on
    /// whichever page is live.
    private func prepareTransition(from previous: UIViewController?, to next: UIViewController) -> (() -> Void)? {
        let opening = overview(in: next), closing = overview(in: previous)
        guard (opening == nil) != (closing == nil), settled, appearance == .visible,
              let id = installedTabID, let outgoing = previous?.viewIfLoaded, outgoing.window != nil,
              let snapshot = outgoing.snapshotView(afterScreenUpdates: false) else { return nil }
        if UIAccessibility.isReduceMotionEnabled {
            return { self.crossfade(snapshot) }
        }
        if let closing {
            // The grid is measured as it was drawn: a card scrolled into view
            // now would be missing from the snapshot, so it crossfades instead.
            guard let card = closing.cardFrame(for: id, in: view, scrollingIntoView: false) else {
                return { self.crossfade(snapshot) }
            }
            return { [self] in
                view.layoutIfNeeded()
                snapshot.frame = view.bounds
                view.insertSubview(snapshot, belowSubview: next.view)
                zoom(page: next.view, content: contentRect(of: next), backdrop: snapshot, card: card, expanding: true)
            }
        }
        let content = contentRect(of: previous)
        return { [self] in
            view.layoutIfNeeded()
            guard let card = opening?.cardFrame(for: id, in: view, scrollingIntoView: true)
            else { return crossfade(snapshot) }
            snapshot.frame = view.bounds
            view.addSubview(snapshot)
            zoom(page: snapshot, content: content, backdrop: next.view, card: card, expanding: false)
        }
    }

    /// The part of a tab's page that its card thumbnail shows — the top
    /// screen's view inside its safe area, which is what `capturePreview`
    /// draws — in the container's coordinates.
    private func contentRect(of controller: UIViewController?) -> CGRect {
        guard let page = (controller as? UINavigationController)?.topViewController?.viewIfLoaded
        else { return view.bounds }
        return page.convert(page.bounds.inset(by: page.safeAreaInsets), to: view)
    }

    /// Scales `page` so that its `content` region lands exactly on `card` —
    /// the thumbnail's frame — masked to that region with the card's bottom
    /// corners, so the bar above the content is cropped away as the page
    /// shrinks and the card's own header takes its place; `backdrop` (the
    /// grid, live or snapshotted) fades on the other side. The page and the
    /// thumbnail coincide at the card end, which is what keeps the final
    /// crossfade from jumping.
    private func zoom(page: UIView, content: CGRect, backdrop: UIView, card: CGRect, expanding: Bool) {
        let bounds = view.bounds
        let scale = card.width / content.width
        // A transform scales about the page's centre, so where the content
        // origin ends up after scaling is what the translation corrects for.
        let shrunk = CGAffineTransform(
            translationX: card.minX - (bounds.midX + (content.minX - bounds.midX) * scale),
            y: card.minY - (bounds.midY + (content.minY - bounds.midY) * scale)
        ).scaledBy(x: scale, y: scale)
        let receded = CGAffineTransform(scaleX: 1.06, y: 1.06)
        let cardMask = CGRect(x: content.minX, y: content.minY, width: content.width, height: card.height / scale)
        let radius = TabSwitcherViewController.cardCornerRadius / scale
        let mask = UIView(frame: expanding ? cardMask : bounds)
        mask.backgroundColor = .black
        mask.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        mask.layer.cornerRadius = expanding ? radius : 0
        page.mask = mask
        page.transform = expanding ? shrunk : .identity
        page.alpha = expanding ? 0 : 1
        backdrop.alpha = expanding ? 1 : 0
        // Opening: the grid only fades in. Scaling it too would move the card
        // under the shrinking page and the two would not meet.
        backdrop.transform = .identity
        let animator = UIViewPropertyAnimator(duration: 0.4, dampingRatio: 0.85) {
            mask.frame = expanding ? bounds : cardMask
            mask.layer.cornerRadius = expanding ? 0 : radius
            page.transform = expanding ? .identity : shrunk
            backdrop.alpha = expanding ? 0 : 1
            backdrop.transform = expanding ? receded : .identity
        }
        // The page's bar and the card's header never line up; a short fade at
        // the card end of the zoom hides the seam.
        if expanding {
            UIView.animate(withDuration: 0.12) { page.alpha = 1 }
        } else {
            animator.addAnimations({ page.alpha = 0 }, delayFactor: 0.7)
        }
        animator.addCompletion { _ in
            page.mask = nil
            page.transform = .identity
            page.alpha = 1
            backdrop.alpha = 1
            backdrop.transform = .identity
        }
        start(animator, removing: expanding ? backdrop : page)
    }

    private func crossfade(_ snapshot: UIView) {
        snapshot.frame = view.bounds
        view.addSubview(snapshot)
        start(UIViewPropertyAnimator(duration: 0.25, curve: .easeInOut) { snapshot.alpha = 0 }, removing: snapshot)
    }

    private func start(_ animator: UIViewPropertyAnimator, removing overlay: UIView) {
        view.isUserInteractionEnabled = false
        animator.addCompletion { [weak self] _ in
            overlay.removeFromSuperview()
            self?.transition = nil
            self?.view.isUserInteractionEnabled = true
        }
        transition = animator
        animator.startAnimation()
    }

    /// Completes an in-flight transition on the spot — before the next swap,
    /// a host change or a rotation — so no overlay outlives the layout it was
    /// measured in. Completion runs synchronously and clears `transition`.
    private func finishTransition() {
        guard let transition, transition.state == .active else { return }
        transition.stopAnimation(false)
        transition.finishAnimation(at: .end)
    }
}

extension TabContainerViewController: UINavigationControllerDelegate {
    func navigationController(
        _ navigation: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        shell?.configureSidebarButton(for: viewController)
        (navigation as? TabNavigationController)?.prepareToolbar(for: viewController)
        navigation.setNavigationBarHidden(false, animated: animated)
        navigation.setToolbarHidden(viewController.toolbarItems?.isEmpty != false, animated: animated)
    }

    func navigationController(
        _ navigation: UINavigationController,
        didShow viewController: UIViewController,
        animated _: Bool
    ) {
        guard navigation === self.navigation else { return }
        // A cancelled interactive pop never reaches willShow for the controller
        // that stays; give it the sidebar toggle back here.
        shell?.configureSidebarButton(for: viewController)
        captureCurrentTab()
    }
}
