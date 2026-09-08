import UIKit

/// The delayed progress card deletion, extraction and Put Back share.
///
/// `show` is a job's `started` hook: the card carries the counts, a Cancel and
/// Continue in Tasks, and reveals itself only after the same delay every other
/// progress card waits out — work that finishes in a blink shows nothing.
///
/// `settle` exists because the card closes itself the moment its job leaves the
/// running list. Where one went up, its dismissal is still animating when the
/// caller has its result, and an alert presented into that beat never appears.
@MainActor
final class JobCover {
    private let center: OperationCenter
    private let presenter: () -> UIViewController?
    private var shown = false

    init(center: OperationCenter, presenter: @escaping () -> UIViewController?) {
        self.center = center
        self.presenter = presenter
    }

    func show(_ identifier: UInt64) {
        guard let presenter = presenter(), let operation = center.operation(forJob: identifier) else { return }
        shown = true
        OperationCoverViewController.present(for: operation.id, from: presenter, center: center)
    }

    func settle(_ complete: @escaping () -> Void) {
        guard shown else { return complete() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: complete)
    }
}
