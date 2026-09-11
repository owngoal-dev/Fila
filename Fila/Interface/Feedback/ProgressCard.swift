import Combine
import UIKit

/// Work that makes the user wait, under the one progress card
/// (`OperationCoverViewController`, the card jobs wear): it appears only once
/// the work has taken a moment, and it is gone before `run` returns.
///
/// Returning only after the dismissal is the point. An alert or a toast the
/// caller shows next would otherwise be presented into the card's own
/// dismissal and never appear.
///
/// Continue closes the card and lets the work finish; `run` still returns its
/// result. Cancel is offered only where `cancellable` says the work can stop
/// part-way without leaving anything half done: it cancels the work, and
/// `run` throws `CancellationError` once the work has stopped — even if the
/// work finished anyway, because the user was told it would not. The work
/// runs in a task of its own, so cancelling the calling task cancels it too.
@MainActor
enum ProgressCard {
    static func run<T: Sendable>(
        title: String,
        message: String,
        cancellable: Bool,
        from presenter: UIViewController,
        operation: @escaping @MainActor (_ update: @escaping @MainActor (String) -> Void) async throws -> T
    ) async throws -> T {
        let state = State(.init(title: title, subtitle: message, progress: nil, isCancellable: cancellable))
        let work = Task { @MainActor in
            try await operation { state.subject.value?.subtitle = $0 }
        }
        let cover = JobCover { [weak presenter] in presenter }
        cover.show(OperationCoverViewController.Source(
            snapshot: { state.subject.value },
            changes: state.subject.map { _ in }.eraseToAnyPublisher(),
            cancel: { work.cancel() }
        ))
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        // Read before the wait: a Cancel tapped while the card is leaving came
        // after the work ended, and must not discard its result.
        let cancelled = work.isCancelled
        state.subject.value = nil
        await cover.settled()
        if cancelled { throw CancellationError() }
        return try result.get()
    }

    @MainActor
    private final class State {
        let subject: CurrentValueSubject<OperationCoverViewController.Source.Snapshot?, Never>
        init(_ snapshot: OperationCoverViewController.Source.Snapshot) {
            subject = CurrentValueSubject(snapshot)
        }
    }
}
