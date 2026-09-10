import AlertController
import Combine
import FilaBackendUI
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Progress content hosted by AlertViewController. OperationCenter owns the
/// result announcement; dismissing this card never announces the job again.
final class OperationCoverViewController: UIViewController {
    private let center: OperationCenter
    private let operationID: UUID
    private var observation: AnyCancellable?
    private var isClosing = false
    /// Fires when this card has finished leaving the screen, exactly once.
    private var onDismiss: (() -> Void)?
    private var progressAnimation: (from: Float, to: Float, started: CFTimeInterval, link: CADisplayLink)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let separator = UIView()
    private let countLabel = UILabel()
    private let backgroundButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let actionStack = UIStackView()

    /// `shown` runs once the card is on screen and `dismissed` once it is off
    /// again — neither runs at all where the job finished inside the reveal
    /// delay and no card was ever presented. A caller with an alert of its own
    /// needs both: one presented into this card's dismissal never appears.
    static func present(
        for operationID: UUID,
        from presenter: UIViewController,
        center: OperationCenter,
        shown: @escaping () -> Void = {},
        dismissed: @escaping () -> Void = {}
    ) {
        Task { @MainActor [weak presenter] in
            try? await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000))
            guard let presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil, !presenter.isBeingDismissed,
                  center.operations.first(where: { $0.id == operationID })?.isRunning == true else { return }
            let content = OperationCoverViewController(center: center, operationID: operationID)
            content.onDismiss = dismissed
            let alert = AlertViewController(contentViewController: content)
            presenter.present(alert, animated: true) {
                shown()
                content.update()
            }
        }
    }

    private init(center: OperationCenter, operationID: UUID) {
        self.center = center
        self.operationID = operationID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        update()
        observation = center.$operations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        update()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation = nil
        stopProgressAnimation()
        // Here rather than in `close`, because the screen underneath can take
        // this card down without asking. Off the row before it runs: whoever
        // waits for the card to be gone is told once, whichever way it went.
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateActionAxis()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            backgroundButton.setNeedsUpdateConfiguration()
            cancelButton.setNeedsUpdateConfiguration()
            view.setNeedsLayout()
        }
    }

    private func build() {
        view.backgroundColor = AlertControllerConfiguration.backgroundColor.withAlphaComponent(0.5)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.addSubview(material)
        material.snp.makeConstraints { $0.edges.equalToSuperview() }

        let artwork = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 12
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
        artwork.snp.makeConstraints { $0.size.equalTo(64) }
        titleLabel.do {
            $0.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.numberOfLines = 0
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        for label in [subtitleLabel, countLabel] {
            label.do {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.adjustsFontForContentSizeCategory = true
                $0.textAlignment = .center
                $0.textColor = .secondaryLabel
                $0.numberOfLines = 0
                $0.setContentCompressionResistancePriority(.required, for: .vertical)
            }
        }
        subtitleLabel.textColor = .label
        subtitleLabel.numberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        spinner.hidesWhenStopped = true
        bar.progressTintColor = AlertControllerConfiguration.accentColor
        let gauge = UIView()
        gauge.addSubview(bar)
        gauge.addSubview(spinner)
        gauge.snp.makeConstraints { $0.height.equalTo(24) }
        bar.snp.makeConstraints { $0.leading.trailing.centerY.equalToSuperview() }
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        separator.backgroundColor = AlertControllerConfiguration.separatorColor
        separator.snp.makeConstraints { $0.height.equalTo(1 / UIScreen.main.scale) }

        configure(backgroundButton, title: String(localized: "Continue"), accented: true)
        backgroundButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        configure(cancelButton, title: String(localized: "Cancel"), accented: false)
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self, let operation = center.operations.first(where: { $0.id == self.operationID }),
                  operation.isCancellable else { return }
            close { self.center.cancel(operation) }
        }, for: .touchUpInside)

        actionStack.do {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.distribution = .fillEqually
            $0.addArrangedSubview(cancelButton)
            $0.addArrangedSubview(backgroundButton)
        }
        let stack = UIStackView(arrangedSubviews: [
            artwork, titleLabel, subtitleLabel, separator, gauge, countLabel, actionStack,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 16
            $0.setCustomSpacing(8, after: gauge)
        }
        // Keep the same compact card at ordinary text sizes. The content can
        // scroll when accessibility text or a short window exceeds its height.
        let scroll = UIScrollView()
        view.addSubview(scroll)
        scroll.snp.makeConstraints { $0.edges.equalToSuperview() }
        scroll.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalTo(scroll.contentLayoutGuide).inset(16)
            $0.width.equalTo(scroll.frameLayoutGuide).offset(-32)
        }
        view.snp.makeConstraints { $0.height.equalTo(stack).offset(32).priority(.high) }
        for child in stack.arrangedSubviews where child !== artwork {
            child.snp.makeConstraints { $0.width.equalTo(stack) }
        }
    }

    /// Match the library's accent/normal actions with accessible UIKit buttons.
    /// The alert library owns the card's width, corner radius and presentation.
    private func configure(_ button: UIButton, title: String, accented: Bool) {
        button.do {
            $0.configuration = UIButton.Configuration.plain().with {
                $0.title = title
                $0.baseForegroundColor = accented
                    ? AlertControllerConfiguration.accentForegroundColor
                    : AlertControllerConfiguration.accentColor
                $0.background.backgroundColor = accented ? AlertControllerConfiguration.accentColor : .clear
                $0.background.strokeColor = AlertControllerConfiguration.accentColor
                $0.background.strokeWidth = 1
                $0.background.cornerRadius = 12
                $0.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
                $0.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = UIFontMetrics(forTextStyle: .body)
                        .scaledFont(for: .systemFont(ofSize: 17, weight: accented ? .semibold : .regular))
                    return outgoing
                }
            }
            $0.titleLabel?.numberOfLines = 0
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget) }
    }

    /// The library places two actions side by side unless either title wraps.
    /// Its layout policy is internal, so apply the same measurement to these
    /// UIKit controls using their dynamically scaled action fonts.
    private func updateActionAxis() {
        let textWidth = (view.bounds.width - 32 - 8) / 2 - 16
        guard textWidth > 0 else { return }
        let needsWrapping = [
            (cancelButton, UIFont.Weight.regular), (backgroundButton, .semibold),
        ].contains { button, weight in
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: weight))
            let height = (button.configuration?.title ?? "").boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            ).height
            return ceil(height) > ceil(font.lineHeight)
        }
        guard (actionStack.axis == .vertical) != needsWrapping else { return }
        actionStack.axis = needsWrapping ? .vertical : .horizontal
        actionStack.distribution = needsWrapping ? .fill : .fillEqually
    }

    private func update() {
        guard !isClosing else { return }
        guard let operation = center.operations.first(where: { $0.id == operationID }), operation.isRunning else {
            // The first observation can arrive while the card is presenting.
            if parent?.presentingViewController != nil, parent?.isBeingPresented == false {
                close()
            }
            return
        }
        titleLabel.text = operation.title
        // One description, not two: the item being worked on now, falling back
        // to what the job is about before the first progress report names one.
        let current = operation.progress.map { ($0.currentPath as NSString).lastPathComponent } ?? ""
        let description = current.isEmpty ? operation.subtitle : current
        subtitleLabel.text = description.isEmpty ? String(localized: "Preparing…") : description
        if let fraction = operation.progress?.fraction {
            updateProgress(Float(fraction))
            bar.isHidden = false
            spinner.stopAnimating()
        } else {
            stopProgressAnimation()
            bar.isHidden = true
            spinner.startAnimating()
        }
        // A rule above a spinner divides the card into nothing. It earns its
        // place only when there is a bar under it.
        separator.isHidden = bar.isHidden
        countLabel.text = operation.progress.map(Self.count(for:))
        countLabel.isHidden = countLabel.text?.isEmpty != false
        cancelButton.isEnabled = operation.isCancellable
    }

    private func close(completion: @escaping () -> Void = {}) {
        guard !isClosing, let alert = parent else { return }
        isClosing = true
        observation = nil
        stopProgressAnimation()
        backgroundButton.isEnabled = false
        cancelButton.isEnabled = false
        alert.dismiss(animated: true, completion: completion)
    }

    private func updateProgress(_ target: Float) {
        let previousTarget = progressAnimation?.to ?? bar.progress
        guard target > 0, target >= previousTarget, !bar.isHidden,
              view.window != nil, !UIAccessibility.isReduceMotionEnabled
        else {
            stopProgressAnimation()
            bar.setProgress(target, animated: false)
            return
        }
        guard target != previousTarget else { return }
        // Continue from the displayed value, without finishing the old spring.
        progressAnimation?.link.invalidate()
        let link = CADisplayLink(target: ProgressTick(owner: self), selector: #selector(ProgressTick.advance(_:)))
        progressAnimation = (bar.progress, target, CACurrentMediaTime(), link)
        link.add(to: .main, forMode: .common)
    }

    private func advanceProgress(_ link: CADisplayLink) {
        guard let animation = progressAnimation else { return }
        let elapsed = max(0, link.timestamp - animation.started)
        guard elapsed < 0.35, view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            stopProgressAnimation()
            return
        }
        // Unit-step response of a spring with damping ratio 0.9. Drive the
        // native bar directly: its built-in animation has no spring control.
        let damping = 0.9
        let frequency = 24.0
        let root = sqrt(1 - damping * damping)
        let phase = frequency * root * elapsed
        let response = 1 - exp(-damping * frequency * elapsed) * (cos(phase) + damping / root * sin(phase))
        let fraction = Float(min(1, max(0, response)))
        bar.setProgress(animation.from + (animation.to - animation.from) * fraction, animated: false)
    }

    private func stopProgressAnimation() {
        guard let animation = progressAnimation else { return }
        animation.link.invalidate()
        progressAnimation = nil
        bar.setProgress(animation.to, animated: false)
    }

    /// CADisplayLink retains its target; this proxy never retains the card.
    @MainActor
    private final class ProgressTick: NSObject {
        private weak var owner: OperationCoverViewController?

        init(owner: OperationCoverViewController) {
            self.owner = owner
        }

        @objc func advance(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advanceProgress(link)
        }
    }

    private static func count(for progress: JobProgress) -> String {
        var parts: [String] = []
        if progress.itemsTotal > 0 {
            parts.append(String(format: String(localized: "%lld of %lld"), progress.itemsDone, progress.itemsTotal))
        }
        if progress.bytesTotal > 0 {
            parts.append(String(
                format: String(localized: "%@ of %@"),
                FilePresentation.byteLabel(progress.bytesDone),
                FilePresentation.byteLabel(progress.bytesTotal)
            ))
        } else if progress.bytesDone > 0 {
            parts.append(FilePresentation.byteLabel(progress.bytesDone))
        }
        return parts.joined(separator: " · ")
    }
}
