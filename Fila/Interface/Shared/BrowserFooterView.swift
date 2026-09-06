import SnapKit
import Then
import UIKit

/// The line under the last row: how many items, which volume, how much of it is
/// left.
///
/// A real section footer inside the collection view, scrolling away with the
/// content. It used to be a label floating in the toolbar over the last row,
/// which read as a notification rather than as part of the list and covered the
/// row it sat on.
final class BrowserFooterView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.trailing.equalTo(layoutMarginsGuide)
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().offset(-FilaUI.Spacing.large)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }
}
