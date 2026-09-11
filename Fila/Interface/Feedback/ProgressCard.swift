import AlertController
import FilaBackendUI
import UIKit

/// The one progress card: work runs under it, it appears only once the work
/// has taken a moment, and it is gone before `run` returns.
///
/// Returning only after the dismissal is the point. An alert or a toast the
/// caller shows next would otherwise be presented into the card's own
/// dismissal and never appear, and state reset in a dismiss completion is
/// state that stays stuck when the card was never shown.
///
/// The work runs in a task of its own, so cancelling the calling task
/// cancels the work too.
@MainActor
enum ProgressCard {
    static func run<T: Sendable>(
        title: String,
        message: String,
        from presenter: UIViewController,
        operation: @escaping @MainActor (_ update: @escaping @MainActor (String) -> Void) async throws -> T
    ) async throws -> T {
        let card = AlertProgressIndicatorViewController(title: title, message: message)
        let reveal = Task { @MainActor [weak presenter] in
            try? await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000))
            guard !Task.isCancelled, let presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
            await withCheckedContinuation { continuation in
                var waiting: CheckedContinuation<Void, Never>? = continuation
                func resume() {
                    waiting?.resume()
                    waiting = nil
                }
                presenter.present(card, animated: true) { resume() }
                // UIKit refuses some presentations — under a sheet that is
                // closing, say — with a log line, and never calls the completion.
                if card.presentingViewController == nil { resume() }
            }
        }
        let work = Task { @MainActor in
            try await operation { card.progressContext.purpose(message: $0) }
        }
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        reveal.cancel()
        await reveal.value
        if card.presentingViewController != nil, !card.isBeingDismissed {
            await withCheckedContinuation { continuation in
                card.dismiss(animated: true) { continuation.resume() }
            }
        }
        return try result.get()
    }
}
