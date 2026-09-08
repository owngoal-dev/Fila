import FilaClient
import FilaProtocol
import FilaRemote
import Foundation

/// Adapts the app's selected file backend to `FilaRemote`.
///
/// Every method is a pass-through onto `FileSession`, and that is the whole
/// design: the WebDAV server never reaches the filesystem itself, so a request
/// that arrived over the network meets `FilaGuard` in exactly the same place a
/// swipe in the browser does. If this file ever grows a `FileManager` call, the
/// server has stopped being a client of the daemon and has become a second,
/// unguarded one.
///
/// Not isolated to the main actor: the server's connections run on
/// `NWListener`'s queue and every call here hops to the actor that owns the
/// link. The type itself holds nothing, which is what makes that safe.
final class WebDAVFileService: RemoteFileService {
    func list(_ directory: String) async throws -> [FileNode] {
        try await DirectoryReader.entries(in: directory, session: FileSession.shared)
    }

    func details(of path: String) async throws -> FileDetails {
        try await FileSession.shared.perform(retryOnDisconnect: true) { try await $0.details(of: path) }
    }

    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32 {
        try await FileSession.shared.perform { try await $0.open(path, flags: flags, mode: mode) }
    }

    func create(_ template: NodeTemplate, at path: String) async throws {
        try await FileSession.shared.perform { try await $0.create(template, at: path) }
    }

    func setAttributes(_ change: AttributeChange, at path: String) async throws {
        try await FileSession.shared.perform { try await $0.setAttributes(change, at: path) }
    }

    func rename(_ source: String, to destination: String, exclusive: Bool) async throws {
        try await FileSession.shared.perform { try await $0.rename(source, to: destination, exclusive: exclusive) }
    }

    func replaceItem(at target: String, withTemporary temporary: String) async throws {
        try await FileSession.shared.perform { try await $0.replaceItem(at: target, withTemporary: temporary) }
    }

    /// Through `OperationCenter`, not straight at the link.
    ///
    /// Two reasons, and neither is tidiness. Job events arrive on one stream
    /// with one consumer, and that consumer is `OperationCenter` — a second
    /// reader would take events away from the transfers list. And a copy
    /// someone started from a Finder window is still work this device is
    /// doing: it belongs in the list, with a stop button, next to the copies
    /// the user started by hand.
    func run(_ job: JobRequest) async throws {
        // Copy, move and delete are the only three the server issues. A search
        // reports its matches on a stream nothing here reads, so asking for one
        // would hang rather than fail.
        guard let kind = Self.kind(of: job) else { throw FilaFailure(code: .invalidRequest) }
        // Silent because nobody in the app asked for this: a Finder window on a
        // mounted volume probes constantly, and a toast per `.DS_Store` it
        // fails to delete would bury the toasts about something the user did.
        // The row still appears in the transfers list, which is the point.
        let failure = try await FileSession.shared.operations.awaitJob(
            job,
            kind: kind,
            subtitle: OperationCenter.describe(job.sources, destination: job.destination),
            feedback: .silent
        )
        guard failure.code == .success else { throw failure }
    }

    private static func kind(of job: JobRequest) -> OperationCenter.Kind? {
        switch job.kind {
        case .copy: .copy
        case .move, .restore: .move
        case .delete: job.useTrash ? .trash : .delete
        case .search, .compress, .extract: nil
        }
    }
}
