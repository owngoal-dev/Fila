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
/// The facts are buttons side by side in a stack rather than one string joined
/// by separators: a separator between every pair is a character the reader has
/// to decode, the distance between two of them is what actually separates them,
/// and each is a way into the thing it describes. They are underlined and
/// pushed to the trailing edge — the slack at the head of the stack takes the
/// width they do not need — so the line reads as a footnote to the list rather
/// than as another row of it.
final class BrowserFooterView: UICollectionReusableView {
    /// One fact in the line, and what touching it opens.
    struct Fact {
        let text: String
        let action: () -> Void
    }

    private let stack = UIStackView()
    /// Absorbs the width the facts do not use: everything to its trailing side
    /// ends up against the margin.
    private let slack = UIView()
    private var buttons: [UIButton] = []

    /// The facts, in the order they are read. Nothing is shown until there is
    /// something to say.
    var facts: [Fact] = [] {
        didSet { render() }
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
        isAccessibilityElement = false
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    private func render() {
        for button in buttons {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = facts.map { fact in
            // An attributed title on a plain button, not a `UIButton.Configuration`:
            // a configuration rebuilds the title from its own attributes and
            // drops the underline, which was measured on the device twice.
            let button = UIButton(type: .system)
            button.setAttributedTitle(NSAttributedString(
                string: fact.text,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .footnote),
                    .foregroundColor: UIColor.secondaryLabel,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
            ), for: .normal)
            button.addAction(UIAction { _ in fact.action() }, for: .touchUpInside)
            // A fact is a control: it dims under the finger like one.
            for event in [UIControl.Event.touchDown, .touchDragEnter] {
                button.addAction(UIAction { [weak button] _ in button?.alpha = 0.5 }, for: event)
            }
            for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                button.addAction(UIAction { [weak button] _ in button?.alpha = 1 }, for: event)
            }
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            return button
        }
        for button in buttons {
            stack.addArrangedSubview(button)
        }
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
