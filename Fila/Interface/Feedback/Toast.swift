import SPIndicator
import Then
import UIKit

/// Queued operation feedback rendered and animated by SPIndicator. The window
/// keeps a completed operation visible across navigation, sheets, and alerts;
/// touches outside the indicator continue to the screen below it.
///
/// One line, and nothing to press. An indicator has no room for a control that
/// reads as one, and the second half of "Moved to Trash · Put Back" was a label
/// people took for a button. Undo lives on its task row, which has an actual
/// button and is still there a minute later.
@MainActor
enum Toast {
    static func show(_ title: String) {
        presenter.enqueue(title)
    }

    private static let presenter = Presenter()
}

@MainActor
private final class Presenter {
    private static let sceneAttempts = 10
    private var queue: [String] = []
    private var window: PassthroughWindow?
    private var indicator: SPIndicatorView?
    private var waiting: Task<Void, Never>?

    func enqueue(_ title: String) {
        queue.append(title)
        guard window == nil, waiting == nil else { return }
        showNext(attempt: 0)
    }

    private func showNext(attempt: Int) {
        waiting = nil
        guard window == nil, let title = queue.first else { return }
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

        let indicator = SPIndicatorView(title: title, message: nil, preset: .done).then {
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.numberOfLines = 1
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = title
        }
        indicator.presentWindow = host
        self.indicator = indicator
        indicator.present(duration: 3, haptic: .none) { [weak self, weak indicator] in
            guard let self, self.indicator === indicator else { return }
            self.indicator = nil
            host.isHidden = true
            window = nil
            showNext(attempt: 0)
        }
        UIAccessibility.post(notification: .announcement, argument: title)
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
