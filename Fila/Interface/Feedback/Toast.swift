import SPIndicator
import Then
import UIKit

/// Queued operation feedback rendered and animated by SPIndicator. The window
/// keeps a completed operation visible across navigation, sheets, and alerts;
/// touches outside the indicator continue to the screen below it.
@MainActor
enum Toast {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    static func show(_ title: String, action: Action? = nil) {
        presenter.enqueue(Item(title: title, action: action))
    }

    fileprivate struct Item {
        let title: String
        let action: Action?
    }

    private static let presenter = Presenter()
}

@MainActor
private final class Presenter {
    private static let sceneAttempts = 10
    private var queue: [Toast.Item] = []
    private var window: PassthroughWindow?
    private var indicator: ActionIndicatorView?
    private var waiting: Task<Void, Never>?

    func enqueue(_ item: Toast.Item) {
        queue.append(item)
        guard window == nil, waiting == nil else { return }
        showNext(attempt: 0)
    }

    private func showNext(attempt: Int) {
        waiting = nil
        guard window == nil, let item = queue.first else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            guard attempt < Self.sceneAttempts else {
                // The Tasks list retains the same result when no scene appears.
                queue.removeAll()
                return
            }
            waiting = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.showNext(attempt: attempt + 1)
            }
            return
        }
        queue.removeFirst()

        let host = PassthroughWindow(windowScene: scene).then {
            $0.windowLevel = .alert + 1
            $0.backgroundColor = .clear
        }
        let root = UIViewController()
        root.view.backgroundColor = .clear
        host.rootViewController = root
        host.isHidden = false
        host.layoutIfNeeded()
        window = host

        let indicator = ActionIndicatorView(item: item)
        indicator.presentWindow = host
        self.indicator = indicator
        indicator.present(duration: item.action == nil ? 3 : 6, haptic: .none) { [weak self, weak indicator] in
            guard let self, self.indicator === indicator else { return }
            self.indicator = nil
            host.isHidden = true
            window = nil
            showNext(attempt: 0)
        }
        UIAccessibility.post(notification: .announcement, argument: indicator.accessibilityLabel)
    }
}

/// SPIndicator supplies the appearance, layout, drag dismissal, and timing.
/// The whole indicator activates its one labeled action, including VoiceOver.
/// The operation's original Undo callback is consumed once.
@MainActor
private final class ActionIndicatorView: SPIndicatorView {
    private var action: Toast.Action?
    private var isDismissing = false

    init(item: Toast.Item) {
        action = item.action
        let title = [item.title, item.action?.title].compactMap(\.self).joined(separator: " · ")
        super.init(title: title, message: nil, preset: .done)
        self.do {
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.numberOfLines = 1
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = title
        }
        if let action = item.action {
            accessibilityTraits = .button
            accessibilityCustomActions = [UIAccessibilityCustomAction(
                name: action.title,
                target: self,
                selector: #selector(activateAction)
            )]
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func dismiss() {
        // Upstream's timer may fire after a tap or drag already dismissed it.
        guard !isDismissing else { return }
        isDismissing = true
        action = nil
        super.dismiss()
    }

    override func accessibilityActivate() -> Bool {
        activateAction()
    }

    @objc private func tapped() {
        _ = activateAction()
    }

    @objc private func activateAction() -> Bool {
        guard !isDismissing, let action else { return false }
        self.action = nil
        dismiss()
        action.handler()
        return true
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === rootViewController?.view {
            return nil
        }
        return hit
    }
}
