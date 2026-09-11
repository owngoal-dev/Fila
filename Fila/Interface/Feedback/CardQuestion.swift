import AlertController
import UIKit

/// A card whose answer is awaited. An action answers with `reply`, which
/// disposes the card first; a card that goes without one — its tab closed,
/// a tap around it — answers `whenGone`, so the caller is never left
/// waiting.
///
/// The answer rides on the card, not on its actions: the package's action
/// context keeps itself, and whatever its actions hold, alive until an
/// action disposes it.
@MainActor
enum CardQuestion {
    private static var key = 0

    static func ask<Value: Sendable>(
        whenGone: Value,
        from presenter: UIViewController,
        _ card: (_ reply: @escaping (ActionContext, Value) -> Void) -> AlertViewController
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation, whenGone: whenGone)
            let alert = card { [weak answer] context, value in
                // Held by the dismissal from here, so the card leaving does
                // not answer first.
                let answer = answer
                context.dispose { answer?.resume(value) }
            }
            objc_setAssociatedObject(alert, &key, answer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(alert, animated: true)
        }
    }

    private final class Answer<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        private let whenGone: Value

        init(_ continuation: CheckedContinuation<Value, Never>, whenGone: Value) {
            self.continuation = continuation
            self.whenGone = whenGone
        }

        func resume(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }

        deinit {
            continuation?.resume(returning: whenGone)
        }
    }
}
