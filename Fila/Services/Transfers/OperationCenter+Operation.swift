import FilaProtocol
import Foundation

/// One row's vocabulary: what was asked for, where it got to, what still holds
/// it, and how it comes back. `OperationCenter` is the list; this is the item.
@MainActor
extension OperationCenter {
    /// What the user asked for. The kind is the only discriminator the surfaces
    /// need — it carries the verb, the icon, and whether the work is over too
    /// fast for a progress row to mean anything.
    enum Kind: String {
        case copy, move, trash, delete, compress, extract, rename, create, attributes, download

        /// Over before a progress row could be read, so its success is invisible
        /// unless something says so. This is the whole difference between a
        /// toast and a transfers entry.
        var isInstant: Bool {
            switch self {
            case .rename, .create, .attributes: true
            default: false
            }
        }
    }

    /// Which outcomes this center announces. A caller that presents its own
    /// failure recovery can keep success feedback without a second error toast.
    enum Feedback {
        case automatic, silent, successOnly
    }

    /// Where an operation is in its life. Three states, not five: `.finished`
    /// carries the daemon's own verdict — `.success`, `.cancelled`, or the
    /// failure — because that is exactly what arrives on the wire, and
    /// splitting it into three cases here only means translating it back at
    /// every use.
    enum State {
        case running(JobProgress?)
        case finished(FilaFailure)
        /// The app was killed while this was running. Nothing came back to say
        /// how it ended, because nothing was left to say it. See `breadcrumb`.
        case interrupted
    }

    /// What is still holding the work, and therefore how it stops. Nil once
    /// nothing is: a finished operation, or one seeded from a breadcrumb.
    enum Control {
        case job(UInt64)
        case task(Task<Void, Never>)
    }

    /// The inverse of an operation, where one genuinely exists.
    ///
    /// Renaming reverses with a rename; trashing restores the recorded item,
    /// using a copy and removal when its origin is on another volume.
    /// The inverse of a copy, a creation or an extraction is a *delete*,
    /// and destroying the user's files to undo is worse than not undoing.
    struct Undo {
        let title: String
        let perform: () async throws -> Void
    }

    struct Operation: Identifiable {
        var id = UUID()
        let kind: Kind
        /// What the row says it is doing: "Copying".
        let title: String
        /// What it is doing it to: "3 items → /var/mobile".
        let subtitle: String
        /// What the *log* calls it, when that cannot be the subtitle.
        ///
        /// `subtitle` is translated user-facing copy — `describe` says
        /// "3 items" through `String(localized:)`, which on a Chinese device is
        /// "3 个项目". A log line is not UI: it is shareable in one tap and it
        /// is read by grep, so a caller that has the real paths puts them here
        /// and the line says the same thing on every device. Nil where the
        /// subtitle is already paths — a rename, a download.
        var logSubject: String?
        var state: State
        /// Directories a finished operation should make reload.
        let affected: [String]
        var control: Control?
        /// Set when the operation starts, kept only if it actually succeeded —
        /// there is nothing to put back after a failure or a cancellation.
        var undo: Undo?
        var feedback: Feedback = .automatic
        /// Called once, with the daemon's own verdict, when the operation ends.
        ///
        /// Resumes `awaitJob` callers only after the row holds the final result.
        var whenFinished: ((FilaFailure) -> Void)?

        /// What a log line calls this operation. Never the localized subtitle
        /// when real paths were recorded — see `logSubject`.
        var logged: String {
            logSubject ?? subtitle
        }

        var isRunning: Bool {
            if case .running = state {
                return true
            }
            return false
        }

        var progress: JobProgress? {
            if case let .running(progress) = state {
                return progress
            }
            return nil
        }

        var succeeded: Bool {
            if case let .finished(failure) = state {
                return failure.code == .success
            }
            return false
        }

        /// The failure worth showing — never `.success`, and never `.cancelled`,
        /// which the user asked for and does not need told about.
        var failure: FilaFailure? {
            guard case let .finished(failure) = state,
                  failure.code != .success, failure.code != .cancelled else { return nil }
            return failure
        }

        var isCancellable: Bool {
            isRunning && control != nil && !kind.isInstant
        }
    }
}
