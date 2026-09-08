import UIKit

/// The delayed progress card deletion, extraction and Put Back share.
///
/// `show` is a job's `started` hook: the card carries the counts, a Cancel and
/// Continue in Tasks, and reveals itself only after the same delay every other
/// progress card waits out — work that finishes in a blink shows nothing.
///
/// `settle` exists because the card closes itself the moment its job leaves the
/// running list, and an alert presented into that dismissal never appears. It
/// waits for the card to actually be gone, and for a job that never showed one
/// it does not wait at all.
@MainActor
final class JobCover {
    private let center: OperationCenter
    private let presenter: () -> UIViewController?
    private var isShowing = false
    private var pending: (() -> Void)?

    init(center: OperationCenter, presenter: @escaping () -> UIViewController?) {
        self.center = center
        self.presenter = presenter
    }

    func show(_ identifier: UInt64) {
        guard let presenter = presenter(), let operation = center.operation(forJob: identifier) else { return }
        OperationCoverViewController.present(
            for: operation.id,
            from: presenter,
            center: center,
            shown: { [weak self] in self?.isShowing = true },
            dismissed: { [weak self] in
                guard let self else { return }
                isShowing = false
                let waiting = pending
                pending = nil
                waiting?()
            }
        )
    }

    func settle(_ complete: @escaping () -> Void) {
        guard isShowing else { return complete() }
        pending = complete
    }
}
