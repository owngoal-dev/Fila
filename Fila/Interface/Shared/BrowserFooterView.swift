import FilaBackendUI
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
///
/// The facts sit side by side in a stack rather than in one string joined by
/// separators: a separator between every pair is a character the reader has to
/// decode, and the distance between two labels is what actually separates them.
/// They are underlined and pushed to the trailing edge — the slack at the head
/// of the stack takes the width the facts do not need — so the line reads as a
/// footnote to the list rather than as another row of it.
final class BrowserFooterView: UICollectionReusableView {
    private let stack = UIStackView()
    /// Absorbs the width the facts do not use: everything to its trailing side
    /// ends up against the margin.
    private let slack = UIView()
    private var labels: [UILabel] = []

    /// The facts, in the order they are read. Nothing is shown until there is
    /// something to say.
    var parts: [String] = [] {
        didSet {
            guard parts != oldValue else { return }
            render()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        slack.do {
            $0.setContentHuggingPriority(.init(1), for: .horizontal)
            $0.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        stack.do {
            $0.axis = .horizontal
            $0.spacing = FilaUI.Spacing.small
            $0.addArrangedSubview(slack)
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalTo(layoutMarginsGuide)
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().offset(-FilaUI.Spacing.large)
        }
        isAccessibilityElement = true
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    private func render() {
        for label in labels {
            stack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        labels = parts.map { part in
            UILabel().then {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.adjustsFontForContentSizeCategory = true
                $0.numberOfLines = 0
                // A fact with content keeps its width; the slack is what gives.
                $0.setContentHuggingPriority(.required, for: .horizontal)
                $0.setContentCompressionResistancePriority(.required, for: .horizontal)
                // Underlined, which a label does through attributed text.
                $0.attributedText = NSAttributedString(
                    string: part,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .footnote),
                        .foregroundColor: UIColor.secondaryLabel,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                )
            }
        }
        for label in labels {
            stack.addArrangedSubview(label)
        }
        // Read as one sentence, in the order the labels are in.
        accessibilityLabel = parts.joined(separator: ", ")
    }

    /// The layout slides a new footer in from the top of the list with the
    /// rows' first diff; the line fades in a second later, once it has
    /// landed. The stack rather than the view, because the collection view
    /// sets the view's alpha from its layout attributes.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reveal), object: nil)
        stack.layer.removeAllAnimations()
        stack.alpha = 0
        if window != nil {
            perform(#selector(reveal), with: nil, afterDelay: 1)
        }
    }

    @objc private func reveal() {
        UIView.animate(withDuration: 0.25) { self.stack.alpha = 1 }
    }
}
