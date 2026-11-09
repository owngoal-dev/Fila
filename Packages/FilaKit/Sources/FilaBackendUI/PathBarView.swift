#if canImport(UIKit)
    import SnapKit
    import Then
    import UIKit

    /// Holds the button's touch-down back until the finger lifts, and knows
    /// whether a finger is still on the button. UIButton opens its primary
    /// menu from the touch-down it is given, so a tap reaches it only after
    /// the lift; its context-menu interaction recognizes a hold on its own
    /// recognizer while the finger is still down. Only a held finger chooses
    /// the hold menu: an activation with no finger at all — VoiceOver's
    /// double-tap, Full Keyboard Access — gets the tap menu, whatever the
    /// last touch was.
    ///
    /// "Held" is read from the touch itself, not from this recognizer's
    /// state: when the hold is recognized UIKit may fail, reset or cancel
    /// this recognizer before it asks for the menu, but the finger's phase
    /// is still what the finger is doing. The lift is also recorded as it
    /// arrives, before the delayed touch-down is handed to the button, so a
    /// tap never reads as a hold however that delivery reports its phase.
    /// The reference is weak, as UIKit asks of anything that keeps a touch.
    private final class HeldTouch: UIGestureRecognizer {
        private weak var touch: UITouch?
        private var lifted = true

        var isHeld: Bool {
            guard !lifted, let touch else { return false }
            return touch.phase == .began || touch.phase == .moved || touch.phase == .stationary
        }

        /// Told on every touch-down: a press that ends as a tap is not the
        /// press that raised the long-press menu.
        var onTouchDown: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
            touch = touches.first
            lifted = false
            onTouchDown?()
        }

        override func touchesMoved(_: Set<UITouch>, with _: UIEvent) {}
        override func touchesEnded(_: Set<UITouch>, with _: UIEvent) {
            lifted = true
            state = .failed
        }

        override func touchesCancelled(_: Set<UITouch>, with _: UIEvent) {
            state = .failed
        }
    }

    private final class CurrentCrumbButton: UIButton {
        var longPressMenu: UIMenu?
        weak var heldTouch: HeldTouch?
        /// Told when the hold menu is the one being built, so a tap that comes
        /// with it does not also open the panel.
        var onLongPressShown: (() -> Void)?

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint,
        ) -> UIContextMenuConfiguration? {
            guard heldTouch?.isHeld == true, let longPressMenu else {
                return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
            }
            onLongPressShown?()
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in longPressMenu }
        }
    }

    /// The breadcrumb.
    ///
    /// A horizontal scroller rather than a truncated label: paths on a jailbroken
    /// device are long and the interesting part is usually the end, so it scrolls to
    /// the trailing edge and every ancestor stays one tap away. A current name too
    /// long for the bar is the exception: the bar shows its beginning — the
    /// chevron before it, its icon, the first characters — because a file is
    /// recognised by how its name starts, and its tail is often a date or an
    /// extension.
    ///
    /// One line of attributed text rather than a row of buttons: the gaps around
    /// each chevron are then the font's own, the same on both sides of every
    /// separator, where a button's insets and image padding never quite were. A
    /// tap lands on the nearest character and takes the crumb attached to it, so
    /// the whole 44pt-high bar is the target and not just the glyphs.
    ///
    /// What a crumb *is* — a folder, a share, a catalogue, an app — is the
    /// caller's: the bar draws titles and icons and reports which crumb was
    /// tapped. The last crumb is where the screen is, drawn as the one dark name
    /// in a row of grey ones. A screen may give that current crumb a menu.
    public final class PathBarView: UIScrollView {
        /// One step of the path: what it says, what it looks like, and the
        /// opaque value the caller wants back when it is tapped.
        public struct Crumb: Equatable {
            public let title: String
            public let target: String
            public let icon: UIImage?

            public init(title: String, target: String = "", icon: UIImage? = nil) {
                self.title = title
                self.target = target
                self.icon = icon
            }
        }

        public var onSelect: ((Crumb) -> Void)?

        /// The current crumb's tap menu. The crumb is drawn the same with or
        /// without one.
        var currentMenu: UIMenu? {
            didSet { applyCurrentTarget() }
        }

        /// A tap on the current crumb that opens the caller's own panel
        /// instead of a menu: a menu's rows take a tap and nothing else, and
        /// a list that is edited by a long press and a drag is not a menu.
        /// Nil leaves the crumb opening `currentMenu`.
        var currentTap: (() -> Void)? {
            didSet { applyCurrentTarget() }
        }

        /// Where the current crumb's tap target is, in this bar's space, so a
        /// panel the tap opens can be anchored to the crumb it came from.
        public var currentTargetFrame: CGRect? {
            currentButton.isHidden ? nil : currentButton.frame
        }

        private var currentTapGesture: UITapGestureRecognizer?
        private var longPressInteraction: UIContextMenuInteraction?
        private var longPressShown = false

        private var hasCurrentTarget: Bool {
            currentMenu != nil || currentTap != nil
        }

        /// One target at a time: the menu opens on touch-down, the panel on
        /// the tap, and a crumb that does neither has nothing to open.
        ///
        /// The long press that opens Places is the interaction UIKit gives a
        /// button with a menu. Taking the menu away takes that with it, so the
        /// interaction is added here by hand for as long as a panel owns the
        /// tap, and a tap that also raised it is not a tap.
        private func applyCurrentTarget() {
            if let currentTapGesture {
                currentButton.removeGestureRecognizer(currentTapGesture)
                self.currentTapGesture = nil
            }
            if currentTap == nil {
                if let longPressInteraction {
                    currentButton.removeInteraction(longPressInteraction)
                    self.longPressInteraction = nil
                }
                currentButton.menu = currentMenu
                currentButton.showsMenuAsPrimaryAction = currentMenu != nil
                setNeedsLayout()
                return
            }
            currentButton.menu = nil
            currentButton.showsMenuAsPrimaryAction = false
            if longPressInteraction == nil, currentButton.longPressMenu != nil {
                let interaction = UIContextMenuInteraction(delegate: currentButton)
                currentButton.addInteraction(interaction)
                longPressInteraction = interaction
            }
            let gesture = UITapGestureRecognizer(target: self, action: #selector(currentTapped))
            currentButton.addGestureRecognizer(gesture)
            currentTapGesture = gesture
            setNeedsLayout()
        }

        @objc private func currentTapped() {
            guard !longPressShown else {
                longPressShown = false
                return
            }
            currentTap?()
        }

        var currentLongPressMenu: UIMenu? {
            didSet {
                currentButton.longPressMenu = currentLongPressMenu
                applyCurrentTarget()
            }
        }

        private let text = UITextView()
        private let currentButton = CurrentCrumbButton(type: .custom)
        private var textWidth: Constraint?
        private var revealsCurrentComponent = true
        private var lastViewportWidth: CGFloat = 0
        /// A highlighter stroke under the current component, behind the text: a
        /// short thick band in a wash of the accent colour, not a text underline.
        private let marker = UIView()
        private var currentRange = NSRange(location: 0, length: 0)
        private var currentTapRange = NSRange(location: 0, length: 0)
        private var shown: [Crumb] = []
        private static let markerHeight: CGFloat = 3
        private static let markerAlpha: CGFloat = 0.2
        /// The index of the crumb a character belongs to, so a tap anywhere on a
        /// crumb — icon, name or the separator after it — finds it.
        private static let component = NSAttributedString.Key("wiki.qaq.fila.pathComponent")
        private static var font: UIFont {
            .preferredFont(forTextStyle: .subheadline)
        }

        private static var currentFont: UIFont {
            .systemFont(ofSize: font.pointSize, weight: .semibold)
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            showsHorizontalScrollIndicator = false
            // A bar item's view: the bar owns the insets, not the safe area.
            contentInsetAdjustmentBehavior = .never
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
            // A transparent menu button covers only the current crumb. Ancestors
            // remain text targets, and the scroll view still owns horizontal pans.
            currentButton.do {
                $0.showsMenuAsPrimaryAction = true
                $0.backgroundColor = .clear
                $0.isHidden = true
            }
            let held = HeldTouch(target: nil, action: nil).then {
                $0.delaysTouchesBegan = true
                $0.cancelsTouchesInView = false
            }
            currentButton.addGestureRecognizer(held)
            currentButton.heldTouch = held
            held.onTouchDown = { [weak self] in self?.longPressShown = false }
            currentButton.onLongPressShown = { [weak self] in self?.longPressShown = true }
            addSubview(currentButton)
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

        /// Draws `crumbs`, the last one as the current place.
        public func setCrumbs(_ crumbs: [Crumb]) {
            // Icons arrive asynchronously. Redrawing the same path with them must
            // not pull the user away from an ancestor they scrolled to.
            let shouldReveal = shown.map(\.target) != crumbs.map(\.target) || revealsCurrentComponent
                || abs(contentOffset.x - revealedOffset) < 1
            shown = crumbs
            let line = NSMutableAttributedString()
            var actions: [UIAccessibilityCustomAction] = []
            currentRange = NSRange(location: 0, length: 0)
            currentTapRange = currentRange
            for (index, crumb) in crumbs.enumerated() {
                let isCurrent = index == crumbs.count - 1
                let componentStart = line.length
                if let image = crumb.icon, image.size.width > 0, image.size.height > 0 {
                    let attachment = NSTextAttachment(image: image)
                    // Fitted into a line-high square, never stretched to it: a
                    // crumb can be a symbol, and a symbol is rarely square.
                    let side = Self.font.lineHeight
                    let scale = min(side / image.size.width, side / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    attachment.bounds = CGRect(
                        x: 0,
                        y: Self.font.descender + (side - size.height) / 2,
                        width: size.width,
                        height: size.height,
                    )
                    let token = NSMutableAttributedString(attachment: attachment)
                    token.append(NSAttributedString(string: " ", attributes: [.font: Self.font]))
                    token.addAttribute(Self.component, value: index, range: NSRange(location: 0, length: token.length))
                    line.append(token)
                }
                // The component the screen is actually showing is where you are
                // rather than somewhere to go: the one dark, weighted name in a
                // row of grey ones, and not a target.
                if isCurrent {
                    currentRange = NSRange(location: line.length, length: (crumb.title as NSString).length)
                }
                line.append(NSAttributedString(string: crumb.title, attributes: [
                    .font: isCurrent ? Self.currentFont : Self.font,
                    .foregroundColor: isCurrent ? UIColor.label : UIColor.secondaryLabel,
                    Self.component: index,
                ]))
                if isCurrent {
                    currentTapRange = NSRange(location: componentStart, length: line.length - componentStart)
                    break
                }
                let separator = NSMutableAttributedString(attributedString: Self.separator)
                separator.addAttribute(Self.component, value: index, range: NSRange(location: 0, length: separator.length))
                line.append(separator)
                actions.append(UIAccessibilityCustomAction(name: crumb.title) { [weak self] _ in
                    self?.onSelect?(crumb)
                    return true
                })
            }
            text.attributedText = line
            text.accessibilityLabel = crumbs.map(\.title).joined(separator: " › ")
            text.accessibilityCustomActions = actions
            currentButton.accessibilityLabel = crumbs.last?.title
            currentButton.isHidden = !hasCurrentTarget || crumbs.isEmpty
            textWidth?.update(offset: ceil(text.sizeThatFits(CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude,
            )).width))
            if shouldReveal {
                revealCurrentComponent()
            }
        }

        public func revealCurrentComponent() {
            revealsCurrentComponent = true
            setNeedsLayout()
        }

        override public func didMoveToWindow() {
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
                withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small),
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
            let offset = min(text.offset(from: text.beginningOfDocument, to: position), storage.length - 1)
            guard offset >= 0, let index = storage.attribute(Self.component, at: offset, effectiveRange: nil) as? Int,
                  index < shown.count - 1 else { return }
            onSelect?(shown[index])
        }

        override public func layoutSubviews() {
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
                    height: Self.markerHeight,
                )
            }
            marker.isHidden = marker.frame.isEmpty || marker.frame.isInfinite
            if hasCurrentTarget,
               let start = text.position(from: text.beginningOfDocument, offset: currentTapRange.location),
               let end = text.position(from: start, offset: currentTapRange.length),
               let range = text.textRange(from: start, to: end)
            {
                // From the current crumb's own first glyph, so the chevron before
                // it stays the previous crumb's target, out over the empty
                // trailing margin, where nothing else can be tapped.
                let glyphs = text.convert(text.firstRect(for: range), to: self)
                currentButton.frame = CGRect(
                    x: glyphs.minX,
                    y: 0,
                    width: glyphs.width + FilaUI.Spacing.large,
                    height: bounds.height,
                )
                currentButton.isHidden = glyphs.isEmpty || glyphs.isInfinite
            } else {
                currentButton.isHidden = true
            }
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
            setContentOffset(CGPoint(x: revealedOffset, y: 0), animated: false)
        }

        /// Where revealing the current crumb scrolls: the trailing edge, unless
        /// that would cut off the crumb's start — then the separator before it
        /// starts at the bar's edge, so its chevron leads and no sliver of the
        /// previous name shows.
        private var revealedOffset: CGFloat {
            let end = max(0, contentSize.width - bounds.width)
            // The separator is two spaces, the chevron and two spaces: five
            // characters before the current crumb.
            let separator = currentTapRange.location - 5
            guard separator >= 0,
                  let start = text.position(from: text.beginningOfDocument, offset: separator),
                  let next = text.position(from: start, offset: 1),
                  let range = text.textRange(from: start, to: next) else { return end }
            let glyph = text.convert(text.firstRect(for: range), to: self)
            guard !glyph.isEmpty, !glyph.isInfinite else { return end }
            return min(end, max(0, glyph.minX))
        }

        override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            // The fonts are baked into the attributed string; a Dynamic Type
            // change re-measures the line by rebuilding it.
            guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
                  !shown.isEmpty else { return }
            setCrumbs(shown)
        }
    }
#endif
