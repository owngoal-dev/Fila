import FilaBackendUI
import UIKit

/// Every destination owns complete chrome before UIKit snapshots either bar.
/// A screen's own buttons are configured in its init; the shell supplies
/// Back and Places from the future stack, and gives the screen the tab's
/// bar — the one Search, breadcrumb and Tabs every page of this tab puts on
/// the bottom bar, so a push finds them already standing — all before the
/// push starts, without waiting for willShow or stealing the source's items.
final class TabNavigationController: UINavigationController {
    weak var owner: RootSplitViewController?

    private lazy var bar = TabContentBar { [weak self] in self?.owner?.presentTabSwitcher() }

    /// The one thing the shell adds to a screen's bottom bar: the tab's
    /// shared controls. Where they sit, and everything beside them, is the
    /// screen's own `TabContentViewController` layout.
    func prepareContent(_ controller: UIViewController) {
        guard let content = controller as? TabContentViewController else {
            assertionFailure("\(type(of: controller)) is in a tab but is not a TabContentViewController")
            return
        }
        guard content.bar !== bar else { return }
        content.bar = bar
    }

    override func setToolbarHidden(_ hidden: Bool, animated: Bool) {
        let hasItems = topViewController?.toolbarItems?.isEmpty == false
        super.setToolbarHidden(!hasItems, animated: animated)
    }

    // MARK: - Transitions that wait for their destination

    /// An animated transition to a screen that fetches on the way in — a
    /// push of a new screen, or a pop back to one that has never listed —
    /// waits for its first rows, up to `preparationBudget`, about three
    /// frames, so the transition lands on content rather than on a wait
    /// that turns into content a moment later. Past the budget the screen
    /// goes up with its loading status and the rows animate in. A pop goes
    /// back to a screen that has never listed more often than it sounds: a
    /// restored tab's parents are made without being shown, and Back at a
    /// jump's root makes the parent it goes to.
    ///
    /// While one transition is waiting, every push queues behind it in the
    /// order it was asked for — a file tapped right after a folder must not
    /// land under the folder. A pop or a stack replacement calls the queue
    /// off, and a queued transition lands only on the stack it was asked
    /// against: the top is still the screen that was on top. A tab switched
    /// away from during the wait keeps its stack in place, so the transition
    /// still lands there — without animation, since nothing is on screen to
    /// animate.
    ///
    /// The interactive pop cannot wait — the finger is already dragging the
    /// screen in — so it goes at once, its destination's listing started
    /// beside it; `prepareBeneathTop` makes that rare.

    /// Screens whose push is waiting on their first rows, in order. A
    /// caller deciding whether a screen is already on its way looks here as
    /// well as at `viewControllers`.
    private(set) var pendingPushes: [UIViewController] = []
    /// The tail of the queue: the transition a new one waits behind.
    private var pendingTransition: (id: UUID, task: Task<Void, Never>)?
    /// Bumped when the queue is called off; a waiting transition compares
    /// what it captured and stands down.
    private var transitionGeneration = 0

    /// Whether a transition is waiting for its destination. The interactive
    /// pop does not begin over one.
    var isTransitionPending: Bool { pendingTransition != nil }

    /// Runs `perform` once `destination` has had its chance at first rows:
    /// now, when it is ready or does not fetch and nothing is waiting ahead
    /// of it; otherwise after the wait, behind whatever is already waiting,
    /// and only if the top is still `expectedTop`. Either way the
    /// destination leaves `pendingPushes` before `perform` is decided on,
    /// so a transition that stands down does not leave its screen looking
    /// as if it were still on its way.
    private func transition(
        to destination: UIViewController,
        animated: Bool,
        onto expectedTop: UIViewController?,
        perform: @escaping (_ animated: Bool) -> Void
    ) {
        let content = destination as? PreparableContent
        let interactive = interactivePopGestureRecognizer.map { $0.state == .began || $0.state == .changed } ?? false
        let waits = animated && !interactive && content?.isPrepared == false
        guard waits || pendingTransition != nil else {
            if interactive, let content, !content.isPrepared {
                Task { await content.prepare(within: FilaUI.preparationBudget) }
            }
            pendingPushes.removeAll { $0 === destination }
            perform(animated)
            return
        }
        let previous = pendingTransition?.task
        let generation = transitionGeneration
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            // Called off while waiting behind the previous one: the
            // destination's listing is not started for a screen that will
            // not be shown.
            guard !Task.isCancelled, self?.transitionGeneration == generation else { return }
            if waits, let content {
                await content.prepare(within: FilaUI.preparationBudget)
            }
            guard let self, generation == transitionGeneration else { return }
            pendingPushes.removeAll { $0 === destination }
            if pendingTransition?.id == id {
                pendingTransition = nil
            }
            // The stack moved under the wait — a pop asked for meanwhile —
            // and a transition on whatever is there now is not the one asked
            // for.
            guard topViewController === expectedTop else { return }
            perform(animated && viewIfLoaded?.window != nil)
        }
        pendingTransition = (id, task)
    }

    /// Nothing queued lands after this: the stack it was asked against is
    /// going away.
    private func dropPendingTransitions() {
        pendingPushes.removeAll()
        transitionGeneration += 1
        pendingTransition?.task.cancel()
        pendingTransition = nil
    }

    /// The screen under the top is where Back goes, and the interactive pop
    /// cannot wait for it. Once a push or a pop has landed, a screen beneath
    /// the top that has never listed gets its first rows off screen. Not on
    /// a stack just installed: its top is about to list, and the parent's
    /// read would be issued ahead of it — a pop from there waits for the
    /// parent itself.
    private func prepareBeneathTop() {
        let prepare = { [weak self] in
            guard let self, viewControllers.count > 1,
                  let content = viewControllers[viewControllers.count - 2] as? PreparableContent,
                  !content.isPrepared else { return }
            Task { await content.prepare(within: FilaUI.preparationBudget) }
        }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { context in
                if !context.isCancelled { prepare() }
            }
        } else {
            prepare()
        }
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        owner?.prepareNavigationItems(for: viewController, in: self, ancestors: viewControllers + pendingPushes)
        prepareContent(viewController)
        let expectedTop = pendingPushes.last ?? topViewController
        pendingPushes.append(viewController)
        transition(to: viewController, animated: animated, onto: expectedTop) { [weak self] animated in
            self?.pushNow(viewController, animated: animated)
        }
    }

    private func pushNow(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController, animated: animated)
        prepareBeneathTop()
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        dropPendingTransitions()
        for (index, controller) in viewControllers.enumerated() {
            owner?.prepareNavigationItems(for: controller, in: self, ancestors: Array(viewControllers.prefix(index)))
            prepareContent(controller)
        }
        super.setViewControllers(viewControllers, animated: animated)
    }

    /// The pops return what they will pop: a caller that must know the
    /// screen is gone waits for the transition, as it would for the
    /// animation.

    override func popViewController(animated: Bool) -> UIViewController? {
        guard viewControllers.count > 1, let destination = viewControllers.dropLast().last else { return nil }
        return popNow(to: destination, animated: animated)?.last
    }

    override func popToViewController(_ viewController: UIViewController, animated: Bool) -> [UIViewController]? {
        popNow(to: viewController, animated: animated)
    }

    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        guard let root = viewControllers.first else { return nil }
        return popNow(to: root, animated: animated)
    }

    private func popNow(to destination: UIViewController, animated: Bool) -> [UIViewController]? {
        guard let index = viewControllers.firstIndex(of: destination), index < viewControllers.count - 1 else { return nil }
        dropPendingTransitions()
        owner?.prepareNavigationItems(for: destination, in: self, ancestors: Array(viewControllers.prefix(index)))
        let popped = Array(viewControllers[(index + 1)...])
        transition(to: destination, animated: animated, onto: topViewController) { [weak self] animated in
            guard let self, viewControllers.contains(where: { $0 === destination }) else { return }
            _ = superPopToViewController(destination, animated: animated)
            prepareBeneathTop()
        }
        return popped
    }

    private func superPopToViewController(_ destination: UIViewController, animated: Bool) -> [UIViewController]? {
        super.popToViewController(destination, animated: animated)
    }
}
