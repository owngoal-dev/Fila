#if canImport(UIKit)
import UIKit

/// Where a tab screen is, as its breadcrumb draws it, and what a tap on an
/// earlier crumb does.
///
/// Read the way a table reads its data source: the screen asks when it is
/// about to appear and whenever it is told the answer changed, and never
/// stores what it is not asked to. A screen that knows where it is conforms
/// itself — a folder, a share, a catalogue and its entries. A screen that is
/// about something else — a terminal for a file, a viewer over a share's
/// snapshot, a page about one part of another page — is given an object
/// that knows, so the screen stays ignorant of paths it never opened.
@MainActor
public protocol TabContentDecorationSource: AnyObject {
    /// The crumbs for `content`, ending with the screen itself. Empty draws
    /// no breadcrumb.
    func decorationCrumbs(for content: TabContentViewController) -> [PathBarView.Crumb]

    /// A crumb before the last was tapped on `content`.
    func tabContent(_ content: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb)
}

/// The breadcrumb of a page about one part of another page: the parent's
/// crumbs, then this page.
///
/// A tap on the parent's own crumb pops back to it; a tap on anything
/// earlier is the parent's to answer, the way it would answer on its own
/// screen. The parent is held weakly: the page outlives nothing, and a
/// parent already gone leaves the page with the crumbs it last drew.
public final class DetailDecoration: TabContentDecorationSource {
    private weak var parent: TabContentViewController?
    private let own: PathBarView.Crumb
    private let parentCrumbs: [PathBarView.Crumb]

    /// `parent` is the page this one continues; `title` and `icon` are this
    /// page's crumb.
    public init(parent: TabContentViewController, title: String, target: String = "", icon: UIImage? = nil) {
        self.parent = parent
        own = PathBarView.Crumb(title: title, target: target, icon: icon)
        parentCrumbs = parent.crumbs
    }

    public func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
        (parent?.crumbs ?? parentCrumbs) + [own]
    }

    public func tabContent(_ content: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb) {
        guard let parent else { return }
        if crumb == parent.crumbs.last, let navigation = content.navigationController,
           navigation.viewControllers.contains(parent)
        {
            navigation.popToViewController(parent, animated: true)
        } else {
            parent.selectDecorationCrumb(crumb)
        }
    }
}
#endif
