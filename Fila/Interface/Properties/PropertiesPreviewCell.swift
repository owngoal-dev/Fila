import SnapKit
import Then
import UIKit

/// A Quick Look-style presentation without copying the file to a preview URL.
final class PropertiesPreviewCell: UITableViewCell {
    private var maximumWidth: Constraint?
    private let preview = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.tintColor = .secondaryLabel
        $0.isAccessibilityElement = false
    }
    private let nameLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .title3)
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }
    private let kindLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let labels = UIStackView(arrangedSubviews: [nameLabel, kindLabel]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(preview)
        contentView.addSubview(labels)
        preview.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.centerX.equalToSuperview()
            maximumWidth = make.width.lessThanOrEqualTo(192).constraint
            make.width.equalTo(contentView.safeAreaLayoutGuide).offset(-FilaUI.Spacing.large * 2).priority(.high)
            make.height.equalTo(preview.snp.width)
        }
        labels.snp.makeConstraints { make in
            make.top.equalTo(preview.snp.bottom).offset(FilaUI.Spacing.medium)
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().inset(FilaUI.Spacing.large)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(image: UIImage?, title: String, kind: String, maximumSide: CGFloat) {
        maximumWidth?.update(offset: maximumSide)
        preview.image = image
        nameLabel.text = title
        kindLabel.text = kind
    }
}
