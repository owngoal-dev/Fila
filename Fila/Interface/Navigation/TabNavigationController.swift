import UIKit

/// Every destination owns complete chrome before UIKit snapshots either bar.
/// Screen buttons are configured in init; the shell supplies Back and Places
/// from the future stack, without waiting for willShow or stealing source items.
final class TabNavigationController: UINavigationController {
    weak var owner: RootSplitViewController?

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        owner?.prepareNavigationItems(for: viewController, in: self, ancestors: viewControllers)
        super.pushViewController(viewController, animated: animated)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        for (index, controller) in viewControllers.enumerated() {
            owner?.prepareNavigationItems(for: controller, in: self, ancestors: Array(viewControllers.prefix(index)))
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
