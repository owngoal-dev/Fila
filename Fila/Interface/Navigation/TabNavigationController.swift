import FilaBackendUI
import UIKit

/// Every destination owns complete chrome before UIKit snapshots either bar.
/// Screen buttons are configured in init; the shell supplies Back and Places
/// from the future stack, without waiting for willShow or stealing source items.
final class TabNavigationController: UINavigationController {
    weak var owner: RootSplitViewController?

    func prepareToolbar(for controller: UIViewController) {
        // A module's detail screen stays within its root screen's stack.
        guard !(controller is any BackendDetailScreen) else { return }
        // A module's root screen exposes Tabs in the leading navigation bar.
        guard !(controller is any BackendRootScreen) else { return }
        var items = controller.toolbarItems ?? []
        guard !items.contains(where: { $0.accessibilityIdentifier == "fila.tabs" }) else { return }
        if #available(iOS 26.0, *), items.isEmpty, controller.navigationItem.searchController != nil {
            controller.navigationItem.preferredSearchBarPlacement = .integrated
            items.append(controller.navigationItem.searchBarPlacementBarButtonItem)
        }
        let tabs = UIBarButtonItem(
            image: UIImage(systemName: "square.on.square"),
            primaryAction: UIAction { [weak self] _ in
                self?.owner?.presentTabSwitcher()
            }
        )
        tabs.accessibilityIdentifier = "fila.tabs"
        tabs.accessibilityLabel = String(localized: "Tabs")
        if #available(iOS 26.0, *) {
            tabs.sharesBackground = false
            tabs.identifier = "tabs"
        }
        controller.setToolbarItems(items + [.flexibleSpace(), tabs], animated: false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let topViewController { prepareToolbar(for: topViewController) }
    }

    override func setToolbarHidden(_ hidden: Bool, animated: Bool) {
        if let topViewController { prepareToolbar(for: topViewController) }
        let hasItems = topViewController?.toolbarItems?.isEmpty == false
        super.setToolbarHidden(!hasItems, animated: animated)
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        owner?.prepareNavigationItems(for: viewController, in: self, ancestors: viewControllers)
        prepareToolbar(for: viewController)
        super.pushViewController(viewController, animated: animated)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        for (index, controller) in viewControllers.enumerated() {
            owner?.prepareNavigationItems(for: controller, in: self, ancestors: Array(viewControllers.prefix(index)))
            prepareToolbar(for: controller)
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
