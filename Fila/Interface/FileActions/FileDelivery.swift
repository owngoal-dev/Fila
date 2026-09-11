import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import UIKit

extension FileReference {
    /// A clipboard or module location, a local one by its path.
    @MainActor
    init(_ location: FileLocation) {
        let local = FileSession.shared.local
        self = location.backend == local.id ? .local(local.absolutePath(location.path)) : .remote(location)
    }
}

/// Copying or moving into a folder anywhere: the one path Paste, a drop and
/// an import take, so all of them ask the same question about names in the
/// way and report a failure the same way.
///
/// Local to local is the native job — copyfile, clonefile, one rename for a
/// same-volume move. Anything that touches a share is a transfer through the
/// operation centre.
@MainActor
enum FileDelivery {
    /// Returns whether everything arrived. Items are carried in groups — the
    /// local ones, then each share's — and the first group that fails stops
    /// the rest. A failure is reported here; a cancellation, or a
    /// replacement declined, is not.
    @discardableResult
    static func deliver(_ items: [FileReference], into folder: FileReference, mode: TransferMode, from presenter: UIViewController?) async -> Bool {
        var paths: [String] = []
        var shares: [BackendID: [FileLocation]] = [:]
        for item in items {
            switch item {
            case let .local(path): paths.append(path)
            case let .remote(location): shares[location.backend, default: []].append(location)
            }
        }
        if !paths.isEmpty, await !deliver(localPaths: paths, into: folder, mode: mode, from: presenter) {
            return false
        }
        for locations in shares.values {
            guard await deliver(locations, into: folder, mode: mode, from: presenter) else { return false }
        }
        return true
    }

    private static func deliver(localPaths paths: [String], into folder: FileReference, mode: TransferMode, from presenter: UIViewController?) async -> Bool {
        switch folder {
        case let .local(directory):
            await native(JobRequest(kind: mode == .move ? .move : .copy, sources: paths, destination: directory), from: presenter)
        case let .remote(destination):
            await transfer(mode: mode, from: presenter) { center, policy in
                await center.transfer(localPaths: paths, into: destination, mode: mode, policy: policy)
            }
        }
    }

    private static func deliver(_ sources: [FileLocation], into folder: FileReference, mode: TransferMode, from presenter: UIViewController?) async -> Bool {
        let destination: FileLocation
        switch folder {
        case let .remote(location):
            destination = location
        case let .local(directory):
            let local = FileSession.shared.local
            guard let path = local.servicePath(forAbsolute: directory) else {
                report(FilaFailure(code: .invalidRequest, path: directory), mode: mode, batch: false)
                return false
            }
            destination = FileLocation(backend: local.id, path: path)
        }
        return await transfer(mode: mode, from: presenter) { center, policy in
            await center.transfer(sources, into: destination, mode: mode, policy: policy)
        }
    }

    /// Files another app hands over — a picker's selection, a drop — taken
    /// into a workspace behind the progress card, then delivered like any
    /// copy. One at a time, so identical names in the selection get the same
    /// replacement question as a collision on disk. Each workspace is removed
    /// whatever happened; the first failure stops the rest.
    static func importFiles(
        count: Int,
        into target: FileReference,
        from presenter: UIViewController,
        prepare: @escaping @MainActor (_ index: Int, _ workspace: URL) async throws -> URL
    ) async {
        do {
            for index in 0 ..< count {
                let workspace = try await FileSession.shared.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: workspace) }
                let file = try await ProgressCard.run(
                    title: String(localized: "Preparing…"),
                    message: String(localized: "Loading the selected file for import."),
                    cancellable: true,
                    from: presenter
                ) { _ in try await prepare(index, workspace) }
                guard await deliver([.local(file.path)], into: target, mode: .copy, from: presenter) else { return }
            }
        } catch {
            reportImport(error)
        }
    }

    /// Silent for a cancellation.
    static func reportImport(_ error: Error) {
        if (error as? FilaFailure)?.code == .cancelled || error is CancellationError { return }
        FeedbackAlert.show(String(localized: "Import Failed"), message: FailureMessage.text(for: error))
    }

    // MARK: - The two carriers

    private static func native(_ request: JobRequest, from presenter: UIViewController?) async -> Bool {
        let center = FileSession.shared.operations
        let kind: OperationCenter.Kind = request.kind == .move ? .move : .copy
        let subtitle = OperationCenter.describe(request.sources, destination: request.destination)
        var outcome: FilaFailure
        do {
            outcome = try await center.awaitJob(request, kind: kind, subtitle: subtitle, feedback: .silent)
            if outcome.systemError == EEXIST, !request.overwrite {
                guard await confirmReplacement(
                    String.LocalizationValue("Items with the same names will be replaced, not moved to the trash. This cannot be undone. Non-empty folders cannot be replaced."),
                    from: presenter
                ) else { return false }
                var replacement = request
                replacement.overwrite = true
                outcome = try await center.awaitJob(replacement, kind: kind, subtitle: subtitle, feedback: .silent)
            }
        } catch let failure as FilaFailure {
            outcome = failure
        } catch {
            outcome = FilaFailure(code: .operationFailed)
        }
        guard outcome.code != .success else { return true }
        if outcome.code != .cancelled {
            report(outcome, mode: request.kind == .move ? .move : .copy, batch: request.sources.count > 1)
        }
        return false
    }

    private static func transfer(
        mode: TransferMode,
        from presenter: UIViewController?,
        _ run: (OperationCenter, PublishPolicy) async -> TransferOutcome
    ) async -> Bool {
        let center = FileSession.shared.operations
        var outcome = await run(center, .failIfExists)
        if case WriteFailure.alreadyExists? = outcome.failure, await confirmReplacement(
            String.LocalizationValue("Files with the same names will be replaced; this cannot be undone. Folders with the same names are merged, and what they already hold is kept."),
            from: presenter
        ) {
            outcome = await run(center, .replace)
        }
        guard let failure = outcome.failure else { return true }
        if !outcome.wasCancelled {
            report(failure, mode: mode, batch: outcome.publishedFiles > 0 || failure is TransferShortfall)
        }
        return false
    }

    // MARK: - Asking and telling

    /// `batch`: part of the request may already have arrived, and the user
    /// should look before trying again.
    private static func report(_ failure: Error, mode: TransferMode, batch: Bool) {
        var message = FailureMessage.text(for: failure)
        if let path = (failure as? FilaFailure)?.path {
            message += "\n\n" + path
        }
        if batch {
            message += "\n\n" + String(localized: "Check the source and destination folders before trying again. Some items may already have been transferred.")
        }
        FeedbackAlert.show(
            mode == .move ? String(localized: "Unable to Move Items") : String(localized: "Unable to Copy Items"),
            message: message
        )
    }

    /// No when nothing can be asked — the screen is gone or busy — and when
    /// the card is torn down with its screen before either action ran.
    private static func confirmReplacement(_ message: String.LocalizationValue, from presenter: UIViewController?) async -> Bool {
        guard let presenter, presenter.viewIfLoaded?.window != nil else { return false }
        var ancestor: UIViewController? = presenter
        while let controller = ancestor {
            guard controller.presentedViewController == nil, !controller.isBeingDismissed else { return false }
            ancestor = controller.parent
        }
        return await CardQuestion.ask(whenGone: false, from: presenter) { reply in
            AlertViewController(title: String.LocalizationValue("Replace Existing Items?"), message: message) { context in
                context.addAction(title: String.LocalizationValue("Cancel")) { reply(context, false) }
                context.addAction(title: String.LocalizationValue("Replace"), attribute: .accent) { reply(context, true) }
            }
        }
    }
}

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
