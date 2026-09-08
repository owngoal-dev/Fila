import FilaProtocol
import SnapKit
import Then
import UIKit

/// Running tasks expose their progress; settled tasks become compact receipts.
///
/// A receipt and nothing else: no control sits on a row here. Cancel belongs to
/// the progress card the job is already showing, and a row in a scrolling list
/// of past results is not where a destructive inverse should be one tap away.
final class TransferCell: UICollectionViewListCell {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let detailLabel = UILabel()
    private let amountLabel = UILabel()
    private let percentageLabel = UILabel()
    private let currentFileLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let progressStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    private func build() {
        symbolView.do {
            $0.contentMode = .center
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
            $0.isAccessibilityElement = false
        }
        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .headline)
            $0.lineBreakMode = .byTruncatingMiddle
            $0.numberOfLines = 0
        }
        subtitleLabel.do {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.textColor = .secondaryLabel
            $0.lineBreakMode = .byTruncatingMiddle
        }
        for label in [detailLabel, amountLabel, percentageLabel, currentFileLabel] {
            label.do {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.textColor = .secondaryLabel
                $0.lineBreakMode = .byTruncatingMiddle
            }
        }
        detailLabel.numberOfLines = 0
        percentageLabel.do {
            $0.font = FilaUI.Font.monospacedFootnote
            $0.textAlignment = .right
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for label in [titleLabel, subtitleLabel, detailLabel, amountLabel, percentageLabel, currentFileLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        let numbers = UIStackView(arrangedSubviews: [spinner, amountLabel, percentageLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.small
        }
        progressStack.do {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.small
            $0.addArrangedSubview(progressView)
            $0.addArrangedSubview(numbers)
            $0.addArrangedSubview(currentFileLabel)
        }
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progressStack, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
            $0.setCustomSpacing(FilaUI.Spacing.medium, after: subtitleLabel)
        }
        contentView.addSubview(symbolView)
        contentView.addSubview(text)
        symbolView.snp.makeConstraints { make in
            make.leading.equalTo(contentView.layoutMarginsGuide)
            make.top.equalTo(text)
            make.width.height.equalTo(FilaUI.IconSize.file)
        }
        text.snp.makeConstraints { make in
            make.leading.equalTo(symbolView.snp.trailing).offset(FilaUI.Spacing.medium)
            make.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalTo(contentView.layoutMarginsGuide).inset(FilaUI.Spacing.compact)
        }
        separatorLayoutGuide.snp.makeConstraints { make in
            make.leading.equalTo(text)
        }
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.isAccessibilityElement = false
        progressView.isAccessibilityElement = false
    }

    func configure(_ operation: OperationCenter.Operation) {
        symbolView.image = UIImage(systemName: operation.kind.symbol)
        symbolView.tintColor = operation.isRunning ? tintColor : .secondaryLabel
        titleLabel.text = operation.succeeded ? operation.kind.completionTitle : operation.title
        subtitleLabel.text = operation.subtitle
        subtitleLabel.isHidden = operation.subtitle.isEmpty
        subtitleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1

        progressStack.isHidden = !operation.isRunning
        detailLabel.isHidden = true
        detailLabel.text = nil
        spinner.stopAnimating()

        switch operation.state {
        case let .running(progress):
            let fraction = progress?.fraction
            progressView.isHidden = fraction == nil
            progressView.progress = Float(fraction ?? 0)
            percentageLabel.isHidden = fraction == nil
            percentageLabel.text = fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
            spinner.isHidden = fraction != nil
            if fraction == nil {
                spinner.startAnimating()
            }
            amountLabel.text = Self.workingAmount(progress)
            currentFileLabel.text = progress.map { ($0.currentPath as NSString).lastPathComponent }
            currentFileLabel.isHidden = currentFileLabel.text?.isEmpty != false

        case let .finished(failure):
            if let real = operation.failure {
                setDetail(FailureText.summary(for: real), color: .systemRed)
            } else if failure.code == .cancelled {
                titleLabel.text = String(localized: "Cancelled")
            }

        case .interrupted:
            setDetail(
                String(localized: "Stopped when Fila closed. Check for incomplete files."),
                color: .systemOrange
            )
        }

        // One element: the whole row is one sentence, and nothing on it is a
        // control VoiceOver would have to reach past it.
        titleLabel.superview?.isAccessibilityElement = true
        titleLabel.superview?.accessibilityLabel = [
            titleLabel.text, operation.subtitle, detailLabel.text,
            operation.isRunning ? amountLabel.text : nil,
            operation.isRunning ? percentageLabel.text : nil,
            operation.isRunning ? currentFileLabel.text : nil,
        ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func setDetail(_ text: String, color: UIColor) {
        detailLabel.text = text
        detailLabel.textColor = color
        detailLabel.isHidden = false
    }

    private static func workingAmount(_ progress: JobProgress?) -> String {
        guard let progress else { return String(localized: "Preparing…") }
        if progress.bytesTotal > 0 {
            return FilePresentation.byteLabel(progress.bytesDone)
                + " / " + FilePresentation.byteLabel(progress.bytesTotal)
        }
        if progress.itemsTotal > 0 {
            return "\(progress.itemsDone) / \(progress.itemsTotal)"
        }
        if progress.bytesDone > 0 {
            return FilePresentation.byteLabel(progress.bytesDone)
        }
        if progress.itemsDone > 0 {
            return String(localized: "\(progress.itemsDone) items")
        }
        return String(localized: "Preparing…")
    }
}
