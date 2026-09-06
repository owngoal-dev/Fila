import SnapKit
import Then
import UIKit

/// The pending operation stays visible while choosing its destination.
final class ClipboardBarView: UIView {
    var onShow: (() -> Void)?
    var onPaste: (() -> Void)?
    var onClear: (() -> Void)?

    private let summary = UIButton(type: .system)
    private let paste = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        summary.do {
            $0.contentHorizontalAlignment = .leading
            $0.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.numberOfLines = 2
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.addAction(UIAction { [weak self] _ in self?.onShow?() }, for: .touchUpInside)
        }
        paste.do {
            $0.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.addAction(UIAction { [weak self] _ in self?.onPaste?() }, for: .touchUpInside)
        }
        let clear = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            $0.tintColor = .secondaryLabel
            $0.accessibilityLabel = String(localized: "Clear Clipboard")
            $0.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        }
        let row = UIStackView(arrangedSubviews: [summary, paste, clear]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.medium
        }
        addSubview(row)
        row.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(FilaUI.Spacing.large)
            make.trailing.equalToSuperview().offset(-FilaUI.Spacing.small)
            make.top.equalToSuperview().offset(FilaUI.Spacing.compact)
            make.bottom.equalToSuperview().offset(-FilaUI.Spacing.compact).priority(.high)
        }
        summary.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        paste.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        clear.snp.makeConstraints { make in
            make.size.equalTo(FilaUI.minimumTapTarget)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func configure(_ clipboard: FileClipboard) {
        let operation = clipboard.isCut ? String(localized: "Move") : String(localized: "Copy")
        summary.setTitle(operation + " · " + String(localized: "\(clipboard.paths.count) items"), for: .normal)
        summary.accessibilityHint = String(localized: "Shows the clipboard.")
        paste.setTitle(clipboard.isCut ? String(localized: "Move Here") : String(localized: "Copy Here"), for: .normal)
        paste.isEnabled = !clipboard.isPasting
    }
}
