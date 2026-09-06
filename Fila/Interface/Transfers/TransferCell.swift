import FilaProtocol
import SnapKit
import Then
import UIKit

/// One transfer: what it is, what it is touching, and how far it has got.
///
/// A hand-built cell rather than a content configuration because a row here is
/// four things at once — an icon, two lines of text, a progress bar and up to
/// two buttons — and it changes several times a second while a copy runs. The
/// list reconfigures it in place; nothing here is rebuilt per tick except the
/// text and the bar.
final class TransferCell: UICollectionViewListCell {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let undoButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var onUndo: (() -> Void)?
    private var onCancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    private func build() {
        symbolView.do {
            $0.contentMode = .center
            $0.tintColor = .secondaryLabel
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.lineBreakMode = .byTruncatingMiddle
        }
        for label in [subtitleLabel, detailLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.lineBreakMode = .byTruncatingMiddle
        }
        detailLabel.numberOfLines = 0
        for label in [titleLabel, subtitleLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        undoButton.do {
            $0.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            $0.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        cancelButton.do {
            $0.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            $0.tintColor = .secondaryLabel
            $0.accessibilityLabel = String(localized: "Cancel")
            $0.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        let heading = UIStackView(arrangedSubviews: [symbolView, titleLabel, UIView(), undoButton, cancelButton]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.small
        }

        // The bar and the spinner share a slot: the totals come from a walk the
        // daemon does as it goes, so "unknown" is a real and common answer and
        // a bar stuck at zero would read as stalled.
        let meter = UIStackView(arrangedSubviews: [progressView, spinner]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.small
        }

        let stack = UIStackView(arrangedSubviews: [heading, subtitleLabel, meter, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        contentView.addSubview(stack)
        symbolView.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.IconSize.inline)
        }
        cancelButton.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.minimumTapTarget).priority(.high)
            make.height.equalTo(FilaUI.minimumTapTarget)
        }
        undoButton.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
        }
    }

    func configure(_ operation: OperationCenter.Operation, center: OperationCenter) {
        symbolView.image = UIImage(systemName: operation.kind.symbol)
        titleLabel.text = operation.title
        subtitleLabel.text = operation.subtitle
        subtitleLabel.isHidden = operation.subtitle.isEmpty

        undoButton.isHidden = operation.undo == nil
        undoButton.setTitle(operation.undo?.title, for: .normal)
        onUndo = { center.undo(operation) }

        cancelButton.isHidden = !operation.isCancellable
        onCancel = { center.cancel(operation) }

        switch operation.state {
        case let .running(progress):
            let fraction = progress?.fraction
            progressView.isHidden = fraction == nil
            progressView.progress = Float(fraction ?? 0)
            spinner.isHidden = fraction != nil
            if fraction == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
            setDetail(Self.workingLine(progress), color: .secondaryLabel)

        case let .finished(failure):
            progressView.isHidden = true
            spinner.isHidden = true
            spinner.stopAnimating()
            if let real = operation.failure {
                setDetail(FailureText.summary(for: real), color: .systemRed)
            } else if failure.code == .cancelled {
                setDetail(String(localized: "Cancelled"), color: .secondaryLabel)
            } else {
                setDetail(operation.kind.completionTitle, color: .secondaryLabel)
            }

        case .interrupted:
            progressView.isHidden = true
            spinner.isHidden = true
            spinner.stopAnimating()
            setDetail(
                String(localized: "Stopped when Fila closed. Check for incomplete files."),
                color: .systemOrange
            )
        }

        accessibilityLabel = [operation.title, operation.subtitle, detailLabel.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func setDetail(_ text: String, color: UIColor) {
        detailLabel.text = text
        detailLabel.textColor = color
    }

    /// Bytes done against total when the total is known, and whatever file the
    /// operation is touching right now.
    private static func workingLine(_ progress: JobProgress?) -> String {
        guard let progress else { return String(localized: "Preparing…") }
        var parts: [String] = []
        if progress.bytesTotal > 0 {
            parts.append(FilePresentation.byteLabel(progress.bytesDone) + " / " + FilePresentation.byteLabel(progress.bytesTotal))
        } else if progress.itemsTotal > 0 {
            parts.append("\(progress.itemsDone) / \(progress.itemsTotal)")
        }
        let name = (progress.currentPath as NSString).lastPathComponent
        if !name.isEmpty { parts.append(name) }
        return parts.isEmpty ? String(localized: "Preparing…") : parts.joined(separator: " · ")
    }
}
