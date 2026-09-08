import UIKit

extension UITableView {
    /// For small tables driven by synchronous values. Call after new data is
    /// ready; diffable lists use their snapshots to animate individual changes.
    func reloadWithAnimation() {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            reloadData()
            return
        }
        UIView.transition(with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.reloadData()
        }
    }
}
