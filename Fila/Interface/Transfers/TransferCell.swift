import FilaProtocol
import SnapKit
import Then
import UIKit

/// Running tasks expose their progress; settled tasks become compact receipts.
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
    private let undoButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var onUndo: (() -> Void)?
    private var onCancel: (() -> Void)?

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
        undoButton.do {
            $0.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        cancelButton.do {
            $0.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            $0.tintColor = .tertiaryLabel
            $0.accessibilityLabel = String(localized: "Cancel")
            $0.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
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
        let actions = UIStackView(arrangedSubviews: [undoButton, cancelButton]).then {
            $0.axis = .horizontal
            // Never stretched to fill the row: a stretched button centres its
            // title, and two rows' Put Back then sit at different distances
            // from the trailing edge. The text beside it takes the slack.
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        let heading = UIStackView(arrangedSubviews: [text, actions]).then {
            $0.axis = .horizontal
            $0.alignment = .top
            $0.spacing = FilaUI.Spacing.small
        }
        contentView.addSubview(symbolView)
        contentView.addSubview(heading)
        symbolView.snp.makeConstraints { make in
            make.leading.equalTo(contentView.layoutMarginsGuide)
            make.top.equalTo(heading)
            make.width.height.equalTo(FilaUI.IconSize.file)
        }
        heading.snp.makeConstraints { make in
            make.leading.equalTo(symbolView.snp.trailing).offset(FilaUI.Spacing.medium)
            make.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalTo(contentView.layoutMarginsGuide).inset(FilaUI.Spacing.compact)
        }
        cancelButton.snp.makeConstraints { make in
            make.width.height.equalTo(FilaUI.minimumTapTarget).priority(.high)
        }
        undoButton.snp.makeConstraints { make in
            make.width.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget).priority(.high)
        }
        separatorLayoutGuide.snp.makeConstraints { make in
            make.leading.equalTo(heading)
        }
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.isAccessibilityElement = false
        progressView.isAccessibilityElement = false
    }

    func configure(_ operation: OperationCenter.Operation, center: OperationCenter) {
        symbolView.image = UIImage(systemName: operation.kind.symbol)
        symbolView.tintColor = operation.isRunning ? tintColor : .secondaryLabel
        titleLabel.text = operation.succeeded ? operation.kind.completionTitle : operation.title
        subtitleLabel.text = operation.subtitle
        subtitleLabel.isHidden = operation.subtitle.isEmpty
        subtitleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1

        undoButton.isHidden = operation.undo == nil
        undoButton.setTitle(operation.undo?.title, for: .normal)
        onUndo = { center.undo(operation) }
        cancelButton.isHidden = !operation.isCancellable
        onCancel = { center.cancel(operation) }
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

        // Keep the text together for VoiceOver while leaving row actions reachable.
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
