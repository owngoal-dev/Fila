#if canImport(UIKit)
import SnapKit
import UIKit

/// A tab screen whose content is one table: a detail page, a fact list, a
/// form of switches.
///
/// What `UITableViewController` gives — a table filling the view, the
/// selection cleared on the way back, the keyboard kept off the rows — is
/// here, on a screen that is a `TabContentViewController` and so carries
/// the same bars as every other page in a tab. The table is this class's
/// own view, which is why it is pinned by hand; data source and delegate
/// are the subclass's.
open class TabContentTableViewController: TabContentViewController, UITableViewDataSource, UITableViewDelegate {
    public let tableView: UITableView

    /// Whether a row left selected is deselected when the screen comes back
    /// — after a push, so Back lands on a list with no row still lit.
    public var clearsSelectionOnViewWillAppear = true

    public init(style: UITableView.Style) {
        tableView = UITableView(frame: .zero, style: style)
        super.init(nibName: nil, bundle: nil)
    }

    override open func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = tableView.backgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        // Under the bars, like every list: the guide follows the bottom edge
        // rather than the safe area where it can, and the table's own inset
        // adjustment keeps the rows clear of the toolbar.
        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.usesBottomSafeArea = false
        }
        tableView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard clearsSelectionOnViewWillAppear, let selected = tableView.indexPathForSelectedRow else { return }
        tableView.deselectRow(at: selected, animated: animated)
    }

    // MARK: - UITableViewDataSource

    open func numberOfSections(in _: UITableView) -> Int {
        1
    }

    open func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        0
    }

    open func tableView(_: UITableView, cellForRowAt _: IndexPath) -> UITableViewCell {
        fatalError("tableView(_:cellForRowAt:) must be overridden")
    }
}
#endif
