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

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        owner?.prepareNavigationItems(for: viewController, in: self, ancestors: viewControllers)
        prepareContent(viewController)
        super.pushViewController(viewController, animated: animated)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        for (index, controller) in viewControllers.enumerated() {
            owner?.prepareNavigationItems(for: controller, in: self, ancestors: Array(viewControllers.prefix(index)))
            prepareContent(controller)
        }
        super.setViewControllers(viewControllers, animated: animated)
    }

    override func popViewController(animated: Bool) -> UIViewController? {
        preparePop(to: viewControllers.dropLast().last)
        return super.popViewController(animated: animated)
    }

    override func popToViewController(_ viewController: UIViewController, animated: Bool) -> [UIViewController]? {
        preparePop(to: viewController)
        return super.popToViewController(viewController, animated: animated)
    }

    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        preparePop(to: viewControllers.first)
        return super.popToRootViewController(animated: animated)
    }

    private func preparePop(to controller: UIViewController?) {
        guard let controller, let index = viewControllers.firstIndex(of: controller) else { return }
        owner?.prepareNavigationItems(for: controller, in: self, ancestors: Array(viewControllers.prefix(index)))
    }
}
