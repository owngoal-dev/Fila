import UIKit

/// The delayed progress card, and the wait for it to be gone. Deletion,
/// extraction and Put Back show a job's card through it; `ProgressCard`
/// shows its own work's.
///
/// `show` puts up the card — counts, Cancel and Continue — only after the
/// same delay every progress card waits out: work that finishes in a blink
/// shows nothing.
///
/// `settle` exists because the card closes itself the moment its work is
/// over, and an alert presented into that dismissal never appears. It waits
/// for the card to actually be gone, and where no card was shown it does not
/// wait at all.
@MainActor
final class JobCover {
    private let presenter: () -> UIViewController?
    private var isShowing = false
    private var pending: (() -> Void)?

    init(presenter: @escaping () -> UIViewController?) {
        self.presenter = presenter
    }

    func show(_ source: OperationCoverViewController.Source) {
        guard let presenter = presenter() else { return }
        OperationCoverViewController.present(
            source,
            from: presenter,
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

    /// A job's `started` hook: its row in `center`, once the job exists.
    func show(job identifier: UInt64, in center: OperationCenter) {
        guard let operation = center.operation(forJob: identifier) else { return }
        show(.operation(operation.id, in: center))
    }

    func settle(_ complete: @escaping () -> Void) {
        guard isShowing else { return complete() }
        pending = complete
    }

    func settled() async {
        await withCheckedContinuation { continuation in settle { continuation.resume() } }
    }
}
