import FilaLog
import SnapKit
import Then
import UIKit

/// Compact message-first entries, matching iGhostVT's journal hierarchy.
/// A bounded preview opens the complete, selectable record on tap.
final class LogRowCell: UICollectionViewCell {
    private static let messageLineCount = 3
    private let messageLabel = UILabel().then {
        $0.font = FilaUI.Font.monospacedBody
        $0.numberOfLines = messageLineCount
        $0.adjustsFontForContentSizeCategory = true
    }
    private let metaLabel = UILabel().then {
        $0.font = FilaUI.Font.monospacedFootnote
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }
    private let separator = UIView().then {
        $0.backgroundColor = .separator
        $0.isUserInteractionEnabled = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let text = UIStackView(arrangedSubviews: [messageLabel, metaLabel]).then {
            $0.axis = .vertical
            $0.alignment = .fill
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(text)
        contentView.addSubview(separator)
        text.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(FilaUI.Spacing.small)
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(FilaUI.Spacing.large)
        }
        separator.snp.makeConstraints { make in
            make.leading.equalTo(text)
            make.trailing.bottom.equalToSuperview()
            make.height.equalTo(1 / traitCollection.displayScale)
        }
        backgroundConfiguration = .listPlainCell()
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func height() -> CGFloat {
        (FilaUI.Font.monospacedBody.lineHeight + FilaUI.Font.monospacedFootnote.lineHeight
            + FilaUI.Spacing.small * 2 + FilaUI.Spacing.compact).rounded(.up)
    }

    func show(_ record: FilaLog.Record) {
        messageLabel.text = record.message
        let color = Self.color(for: record.level)
        messageLabel.textColor = color
        var metadata = [LogViewController.timeText(record.time), record.source.name]
        if record.level != .info { metadata.append(record.level.tag) }
        metaLabel.text = metadata.joined(separator: " · ")
        metaLabel.textColor = record.level >= .warning ? color.withAlphaComponent(0.8) : .tertiaryLabel
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = record.level >= .warning ? color.withAlphaComponent(0.06) : .systemBackground
        backgroundConfiguration = background
        accessibilityLabel = LogViewController.exportLine(record)
    }

    private static func color(for level: FilaLog.Level) -> UIColor {
        switch level {
        case .verbose: return .secondaryLabel
        case .info: return .label
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }
}
