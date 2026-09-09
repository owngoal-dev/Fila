#if canImport(UIKit)
import SnapKit
import Then
import UIKit

/// The bottom-bar controls one tab keeps across its pages: one Search, one
/// breadcrumb, one Tabs.
///
/// A page that hands UIKit a fresh set of items makes the bar blur its old
/// set out and the new one in with the push, even when the new items look
/// the same. Reusing the same objects on every page leaves them standing;
/// only the breadcrumb's text changes, which it must. The shell makes one
/// of these per tab and gives it to every page it pushes; a page shown
/// outside a tab has none and falls back to controls of its own.
@MainActor
public final class TabContentBar {
    /// Search, for the page that says it wants one: the tap goes to the
    /// page the bar currently shows.
    public let searchItem: UIBarButtonItem

    /// The breadcrumb, showing the current page's crumbs.
    public let pathBar = PathBarView()
    let pathBarItem: UIBarButtonItem
    var pathBarWidth: Constraint?

    /// The Tabs control.
    public let tabsItem: UIBarButtonItem

    let leadingSpace = UIBarButtonItem.flexibleSpace()
    let trailingSpace = UIBarButtonItem.flexibleSpace()

    /// The page whose crumbs the bar shows and whose search the button
    /// opens: the one appearing, from its `viewWillAppear` on.
    public private(set) weak var current: TabContentViewController?

    public init(showTabs: @escaping () -> Void) {
        searchItem = UIBarButtonItem(systemItem: .search).then {
            if #available(iOS 26.0, *) {
                $0.identifier = "search"
                $0.sharesBackground = false
            }
        }
        tabsItem = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), primaryAction: UIAction { _ in
            showTabs()
        }).then {
            $0.accessibilityLabel = String(localized: "Tabs", bundle: .module)
            $0.accessibilityIdentifier = "fila.tabs"
            if #available(iOS 26.0, *) {
                $0.identifier = "tabs"
                $0.sharesBackground = false
            }
        }
        pathBarItem = UIBarButtonItem(customView: pathBar).then {
            if #available(iOS 26.0, *) {
                $0.identifier = "path"
                $0.sharesBackground = false
            }
        }
        // The bar owns the breadcrumb's material and layout. Its custom view
        // receives only the width left after the other slots and their gaps;
        // the current page keeps that up to date from its own layout.
        pathBar.snp.makeConstraints { make in
            pathBarWidth = make.width.equalTo(FilaUI.minimumTapTarget).constraint
            make.height.equalTo(FilaUI.minimumTapTarget)
        }
        searchItem.primaryAction = UIAction { [weak self] _ in self?.current?.search() }
        pathBar.onSelect = { [weak self] crumb in self?.current?.selectDecorationCrumb(crumb) }
    }

    /// Shows `page` on the bar: its crumbs, and its search behind the button.
    func adopt(_ page: TabContentViewController) {
        current = page
        pathBar.setCrumbs(page.crumbs)
    }
}
#endif
