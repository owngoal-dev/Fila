import UIKit

/// `UITableViewDiffableDataSource` that still answers the plain header and
/// footer titles.
///
/// `titleForHeaderInSection` is a *data source* method, and once a table is
/// diffable the data source is this object rather than the controller — so a
/// grouped screen that moves to a snapshot silently loses every section title
/// unless something takes them over. Subclassing is the documented way, and one
/// subclass here is the alternative to one per screen.
///
/// The closures are asked per draw and answer from the controller's own state,
/// which is what keeps a title that counts something ("Move · 3 items") honest
/// without the count becoming a second thing to keep in the snapshot.
final class TitledTableDataSource<Section: Hashable, Item: Hashable>: UITableViewDiffableDataSource<Section, Item> {
    var header: ((Section) -> String?)?
    var footer: ((Section) -> String?)?

    override func tableView(_: UITableView, titleForHeaderInSection index: Int) -> String? {
        sectionIdentifier(for: index).flatMap { header?($0) }
    }

    override func tableView(_: UITableView, titleForFooterInSection index: Int) -> String? {
        sectionIdentifier(for: index).flatMap { footer?($0) }
    }
}
