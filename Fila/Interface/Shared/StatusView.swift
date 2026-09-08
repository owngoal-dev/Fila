import SnapKit
import Then
import UIKit

/// What a screen shows when it has no rows.
///
/// A list with nothing in it is three different facts drawn identically — still
/// working, nothing to show, could not read it — and a file manager that spells
/// all three as a blank rectangle has told the user nothing. This is the one
/// view that spells them apart, and it is deliberately the only one: five
/// variations of the same panel is how two screens end up disagreeing about
/// what an empty folder looks like.
///
/// Put it in a `UICollectionView.backgroundView` (see `showStatus`) or a
/// `UITableView.backgroundView`. `UIContentUnavailableConfiguration` is the
/// modern spelling of this and it is iOS 17; the app ships to 15.
final class StatusView: UIView {
    enum Content: Equatable {
        /// Work in flight, with an exit on both sides — the caller replaces it
        /// with rows, a message, or nothing.
        case loading(String, detail: String? = nil)
        /// A settled fact: an SF Symbol — or a piece of the app's own artwork
        /// under `FileIcons`, drawn at up to 96 points — a line, optionally the
        /// detail behind it, and optionally one thing to do about it — the
        /// button's title; what it does is `StatusView.action`, set by whoever
        /// shows the panel.
        case message(
            symbol: String,
            artwork: String? = nil,
            title: String,
            detail: String? = nil,
            button: String? = nil
        )
    }

    /// What the button does. Kept beside the content rather than in it so
    /// that `Content` stays a value that can be compared.
    var action: (() -> Void)?

    /// How long a file operation may run before its progress card is worth
    /// presenting; one that finishes in a blink never shows the card. The
    /// loading panel itself has no such delay: a spinner from the first frame
    /// reads as the app working, a blank screen reads as it hanging.
    static let revealDelay: TimeInterval = 0.35

    /// Centres the content in the band above the keyboard instead of the
    /// whole view, riding the keyboard's own animation through the layout
    /// guide. Fixed at construction; the panel is built once per owner.
    private let followsKeyboard: Bool

    var content: Content {
        didSet {
            guard content != oldValue else { return }
            apply()
        }
    }

    private let spinner = UIActivityIndicatorView(style: .large)
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private lazy var button = UIButton(configuration: .borderedProminent(), primaryAction: UIAction { [weak self] _ in
        self?.action?()
    })

    init(content: Content, followsKeyboard: Bool = false) {
        self.content = content
        self.followsKeyboard = followsKeyboard
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Hierarchy

    private func build() {
        spinner.hidesWhenStopped = true

        symbolView.do {
            $0.contentMode = .scaleAspectFit
            $0.tintColor = .secondaryLabel
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .light)
        }

        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .headline)
            $0.textColor = .label
        }
        detailLabel.do {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.textColor = .secondaryLabel
        }

        for label in [titleLabel, detailLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = true
        }

        let stack = UIStackView(arrangedSubviews: [symbolView, titleLabel, detailLabel, button]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = FilaUI.Spacing.small
            $0.setCustomSpacing(FilaUI.Spacing.medium, after: symbolView)
            $0.setCustomSpacing(FilaUI.Spacing.large, after: detailLabel)
        }
        addSubview(band)
        addSubview(stack)
        addSubview(spinner)
        spinner.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(stack.snp.top).offset(-FilaUI.Spacing.small)
        }
        // Artwork comes at the properties page's 192 points; here it is a
        // glyph, not a preview. A symbol is smaller than this and unaffected.
        symbolView.snp.makeConstraints { make in
            make.width.height.lessThanOrEqualTo(96)
        }

        // The width has to have a floor, not just a ceiling. With only the two
        // inequalities the stack was free to shrink to its labels' minimum —
        // and a label whose width is unconstrained collapses to one character
        // per line in a narrow column.
        // So: fill the available width, but never more than a comfortable
        // measure. The fill is not required, so it yields in a column narrower
        // than the margins rather than overflowing it.
        stack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(band.snp.centerY)
            make.leading.greaterThanOrEqualTo(layoutMarginsGuide)
            make.trailing.lessThanOrEqualTo(layoutMarginsGuide)
            make.width.lessThanOrEqualTo(320)
            make.width.equalTo(layoutMarginsGuide).priority(.high)
        }

        // A one-point tall view spanning from the view's top edge to the
        // keyboard's: its centre is the middle of the band above the keyboard,
        // and pinning the stack's centre to it centres the panel there. The
        // keyboard guide tracks the keyboard frame and animates with its own
        // curve, so the panel rides along as the keyboard appears or hides.
        // (Without the keyboard in the way the band is the whole view and the
        // midpoint is the view's centre — the ordinary placement.) Only the
        // guide's bottom edge is conditional, so a keyboard moving in or out
        // relayouts the panel with it; no constraint swap, no priority game.
        band.snp.makeConstraints { make in
            make.top.equalTo(snp.top)
            make.bottom.equalTo(followsKeyboard ? keyboardLayoutGuide.snp.top : snp.bottom)
            make.width.equalTo(self).priority(.low)
            make.centerX.equalToSuperview()
        }
    }

    private let band = UIView()

    // MARK: - State

    private func apply() {
        let title: String
        let detail: String?
        let buttonTitle: String?
        let isLoading: Bool
        switch content {
        case let .loading(text, note):
            (title, detail, buttonTitle, isLoading) = (text, note, nil, true)
        case let .message(symbol, artwork, text, note, verb):
            (title, detail, buttonTitle, isLoading) = (text, note, verb, false)
            symbolView.image = artwork.flatMap { UIImage(named: "FileIcons/\($0)") }?.withRenderingMode(.alwaysOriginal)
                ?? UIImage(systemName: symbol)
        }
        // Stopping owns visibility too. A hidden but still-running indicator
        // can reappear when UIKit resumes its animation after backgrounding.
        if isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        symbolView.isHidden = isLoading
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        button.configuration?.title = buttonTitle
        button.isHidden = buttonTitle == nil

        // This is the whole content of the screen when it is showing, so it is
        // what VoiceOver has to read: one element, both lines, rather than two
        // labels a rotor has to be walked through — unless there is a button,
        // which has to stay reachable on its own.
        isAccessibilityElement = buttonTitle == nil
        accessibilityLabel = [title, detail].compactMap(\.self).joined(separator: ", ")
        accessibilityTraits = isLoading ? .updatesFrequently : .staticText
    }

    override func updateConstraints() {
        super.updateConstraints()
        let safeAreaGuide = findViewController()?.view.safeAreaLayoutGuide
        band.snp.remakeConstraints { make in
            make.top.equalTo(safeAreaGuide?.snp.top ?? snp.top)
            make.bottom.equalTo(followsKeyboard ? keyboardLayoutGuide.snp.top : snp.bottom)
            make.width.equalTo(self).priority(.low)
            make.centerX.equalToSuperview()
        }
    }
}

extension UICollectionView {
    /// Puts a `StatusView` behind the rows, or takes it away. Nil means the
    /// list has content and needs no explanation.
    ///
    /// Reuse the panel across listing pages; unchanged content is a no-op.
    ///
    /// A list section's background decoration is drawn *over* `backgroundView`,
    /// so a list layout that has one hides this panel completely. The browser's
    /// list configuration clears its section background for that reason; a new
    /// caller that finds this panel invisible should check the same thing
    /// before assuming the panel is broken.
    /// State changes are immediate; the indicator only animates its rotation.
    func showStatus(_ content: StatusView.Content?, action: (() -> Void)? = nil, followsKeyboard: Bool = false) {
        guard let content else {
            guard backgroundView is StatusView else { return }
            backgroundView = nil
            return
        }
        // The flag shapes the panel's constraints, and a panel is built once
        // per owner — so it only matters when the panel is first created.
        let panel = backgroundView as? StatusView ?? StatusView(content: content, followsKeyboard: followsKeyboard)
        panel.action = action
        panel.content = content
        backgroundView = panel
    }
}

fileprivate extension UIView {
    func findViewController() -> UIViewController? {
        if let nextResponder = self.next as? UIViewController {
            return nextResponder
        } else if let nextResponder = self.next as? UIView {
            return nextResponder.findViewController()
        }
        return nil
    }
}
