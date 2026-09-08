import SnapKit
import Then
import UIKit

/// The breadcrumb.
///
/// A horizontal scroller rather than a truncated label: paths on a jailbroken
/// device are long and the interesting part is usually the end, so it scrolls to
/// the trailing edge and every ancestor stays one tap away.
///
/// One line of attributed text rather than a row of buttons: the gaps around
/// each chevron are then the font's own, the same on both sides of every
/// separator, where a button's insets and image padding never quite were. A
/// tap lands on the nearest character and takes the path attached to it, so
/// the whole 44pt-high bar is the target and not just the glyphs.
final class PathBarView: UIScrollView {
    var onSelect: ((String) -> Void)?

    private let text = UITextView()
    private var textWidth: Constraint?
    private var revealsCurrentComponent = true
    private var lastViewportWidth: CGFloat = 0
    /// A highlighter stroke under the current component, behind the text: a
    /// short thick band in a wash of the accent colour, not a text underline.
    private let marker = UIView()
    private var currentRange = NSRange(location: 0, length: 0)
    private var shown: (path: String, icon: (String) -> UIImage?)?
    private static let markerHeight: CGFloat = 3
    private static let markerAlpha: CGFloat = 0.2
    /// The path a crumb opens. The current component carries an empty string,
    /// so a tap on it finds an answer — "nowhere" — instead of walking back to
    /// the ancestor before it.
    private static let component = NSAttributedString.Key("wiki.qaq.fila.pathComponent")
    private static var font: UIFont {
        .preferredFont(forTextStyle: .subheadline)
    }

    private static var currentFont: UIFont {
        .systemFont(ofSize: font.pointSize, weight: .semibold)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        marker.do {
            $0.backgroundColor = tintColor.withAlphaComponent(Self.markerAlpha)
            $0.layer.cornerRadius = Self.markerHeight / 2
            $0.isUserInteractionEnabled = false
        }
        addSubview(marker)
        text.do {
            $0.isEditable = false
            $0.isSelectable = false
            $0.isScrollEnabled = false
            $0.backgroundColor = .clear
            $0.textContainerInset = .zero
            $0.textContainer.lineFragmentPadding = 0
            $0.textContainer.maximumNumberOfLines = 1
            $0.textContainer.lineBreakMode = .byClipping
            $0.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }
        addSubview(text)
        text.snp.makeConstraints { make in
            make.leading.equalTo(contentLayoutGuide).offset(FilaUI.Spacing.large)
            make.trailing.equalTo(contentLayoutGuide).offset(-FilaUI.Spacing.large)
            make.top.bottom.equalTo(contentLayoutGuide)
            make.height.equalTo(frameLayoutGuide)
            textWidth = make.width.equalTo(0).constraint
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    /// `icon` answers each crumb's path with the token drawn ahead of its
    /// name at the text's own height; nil draws none.
    func setPath(_ path: String, icon: @escaping (String) -> UIImage? = { _ in nil }) {
        // Folder icons arrive asynchronously. Refreshing those for the same
        // path must not pull the user away from an ancestor they scrolled to.
        let shouldReveal = shown?.path != path || revealsCurrentComponent
            || abs(contentOffset.x - max(0, contentSize.width - bounds.width)) < 1
        shown = (path, icon)
        // The root is the device, not a slash: the name when the entitlement
        // lets us read it, the model otherwise.
        var crumbs = [(title: "@" + UIDevice.current.name, path: "/")]
        var prefix = ""
        for component in path.split(separator: "/").map(String.init) {
            prefix += "/" + component
            crumbs.append((component, prefix))
        }
        let line = NSMutableAttributedString()
        var actions: [UIAccessibilityCustomAction] = []
        for (index, crumb) in crumbs.enumerated() {
            let isCurrent = index == crumbs.count - 1
            // The icon belongs to the crumb's tap range too, so a tap on it
            // opens this folder and not the one before it.
            let target = isCurrent ? "" : crumb.path
            if let image = icon(crumb.path) {
                let attachment = NSTextAttachment(image: image)
                let side = Self.font.lineHeight
                attachment.bounds = CGRect(x: 0, y: Self.font.descender, width: side, height: side)
                let token = NSMutableAttributedString(attachment: attachment)
                token.append(NSAttributedString(string: " ", attributes: [.font: Self.font]))
                token.addAttribute(Self.component, value: target, range: NSRange(location: 0, length: token.length))
                line.append(token)
            }
            // The component the browser is actually showing is where you are
            // rather than somewhere to go: the one dark, weighted name in a
            // row of grey ones, and not a target.
            if isCurrent {
                currentRange = NSRange(location: line.length, length: (crumb.title as NSString).length)
            }
            line.append(NSAttributedString(string: crumb.title, attributes: [
                .font: isCurrent ? Self.currentFont : Self.font,
                .foregroundColor: isCurrent ? UIColor.label : UIColor.secondaryLabel,
                Self.component: target,
            ]))
            guard !isCurrent else { break }
            line.append(Self.separator)
            actions.append(UIAccessibilityCustomAction(name: crumb.title) { [weak self] _ in
                self?.onSelect?(crumb.path)
                return true
            })
        }
        text.attributedText = line
        text.accessibilityLabel = path
        text.accessibilityCustomActions = actions
        textWidth?.update(offset: ceil(text.sizeThatFits(CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )).width))
        if shouldReveal {
            revealCurrentComponent()
        }
    }

    func revealCurrentComponent() {
        revealsCurrentComponent = true
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            revealCurrentComponent()
        }
    }

    /// A chevron drawn as a symbol attachment, so it sits on the text's own
    /// baseline and scales with it, with one space of the same font either side.
    private static var separator: NSAttributedString {
        let chevron = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )?.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        let line = NSMutableAttributedString(string: "  ", attributes: [.font: font])
        if let chevron {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: chevron)))
        }
        line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        return line
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        // The nearest character rather than a hit test, so a tap above or below
        // the line — the bar is taller than the text — still lands on a crumb.
        // A tap on a separator belongs to the crumb before it.
        guard let position = text.closestPosition(to: recognizer.location(in: text)) else { return }
        let storage = text.textStorage
        var index = min(text.offset(from: text.beginningOfDocument, to: position), storage.length - 1)
        while index >= 0 {
            if let path = storage.attribute(Self.component, at: index, effectiveRange: nil) as? String {
                if !path.isEmpty {
                    onSelect?(path)
                }
                return
            }
            index -= 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Vertically centre the single line in the bar; the text view's own
        // inset is the only knob that moves text without moving the view.
        let inset = max(0, (bounds.height - Self.font.lineHeight) / 2)
        if abs(text.textContainerInset.top - inset) > 0.5 {
            text.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
            text.layoutIfNeeded()
        }
        // The band sits across the bottom of the current name's glyphs, a
        // little under the baseline, the way a highlighter drags under a word.
        marker.backgroundColor = tintColor.withAlphaComponent(Self.markerAlpha)
        if let start = text.position(from: text.beginningOfDocument, offset: currentRange.location),
           let end = text.position(from: start, offset: currentRange.length),
           let range = text.textRange(from: start, to: end)
        {
            let glyphs = text.convert(text.firstRect(for: range), to: self)
            marker.frame = CGRect(
                x: glyphs.minX,
                y: glyphs.maxY - Self.font.descender.magnitude - Self.markerHeight,
                width: glyphs.width,
                height: Self.markerHeight
            )
        }
        marker.isHidden = marker.frame.isEmpty || marker.frame.isInfinite
        if abs(bounds.width - lastViewportWidth) > 0.5 {
            lastViewportWidth = bounds.width
            revealsCurrentComponent = true
        }
        // An explicit pan wins over an appearance or size change that happens
        // in the same layout pass. Ordinary scrolling never resets the offset.
        if isTracking || isDragging || isDecelerating {
            revealsCurrentComponent = false
            return
        }
        guard revealsCurrentComponent, window != nil, bounds.width > 0, contentSize.width > 0 else { return }
        revealsCurrentComponent = false
        setContentOffset(CGPoint(x: max(0, contentSize.width - bounds.width), y: 0), animated: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // The fonts are baked into the attributed string; a Dynamic Type
        // change re-measures the line by rebuilding it.
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
              let shown else { return }
        setPath(shown.path, icon: shown.icon)
    }
}
