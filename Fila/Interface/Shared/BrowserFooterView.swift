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
final class BrowserFooterView: UICollectionReusableView {
    private let stack = UIStackView()

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
        stack.do {
            $0.axis = .horizontal
            $0.spacing = FilaUI.Spacing.small
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            // Centred, but free to wrap inside the margins on a narrow screen.
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualTo(layoutMarginsGuide.snp.leading)
            make.trailing.lessThanOrEqualTo(layoutMarginsGuide.snp.trailing)
            make.top.equalToSuperview().offset(FilaUI.Spacing.large)
            make.bottom.equalToSuperview().offset(-FilaUI.Spacing.large)
            make.height.equalToSuperview().offset(-FilaUI.Spacing.large * 2).priority(.high)
        }
        isAccessibilityElement = true
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    private func render() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for part in parts {
            stack.addArrangedSubview(UILabel().then {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.adjustsFontForContentSizeCategory = true
                $0.textColor = .secondaryLabel
                $0.numberOfLines = 0
                $0.text = part
            })
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
