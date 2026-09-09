import FilaClient
import FilaProtocol
import Foundation

// MARK: - Inverses

@MainActor
extension OperationCenter {
    /// The job identity and canonical origin survive cross-volume copying.
    /// Matching both keeps an old Undo from picking up a later deletion.
    func putBack(_ origins: [String], identity: UUID) async throws {
        var byVolume: [String: [String]] = [:]
        for origin in origins {
            let directory = (origin as NSString).deletingLastPathComponent
            let volume = try await session.perform(retryOnDisconnect: true) {
                try await $0.volumeInfo(for: directory)
            }
            byVolume[volume.mountPoint, default: []].append(origin)
        }
        for (mountPoint, group) in byVolume {
            let found = try await locate(group, identity: identity, inTrashOf: mountPoint)
            for origin in group {
                guard let source = found[origin] else { throw FilaFailure(code: .notFound, path: origin) }
                try await restore(source, to: origin, identity: identity)
            }
        }
    }

    private func locate(
        _ origins: [String],
        identity: UUID,
        inTrashOf mountPoint: String
    ) async throws -> [String: String] {
        guard let backend = session.hello?.backend else { return [:] }
        let directory = LocalFileBackend.trashDirectory(backend: backend, volume: mountPoint)
        let wanted = Set(origins)
        var found: [String: String] = [:]
        for try await page in DirectoryReader.pages(in: directory, session: session) {
            for node in page {
                let path = Self.join(directory, node.name)
                do {
                    let recorded = try await session.perform(retryOnDisconnect: true) {
                        try await $0.extendedAttribute(FilaTrash.jobAttribute, at: path)
                    }
                    guard recorded == Data(identity.uuidString.utf8) else { continue }
                    let data = try await session.perform(retryOnDisconnect: true) {
                        try await $0.extendedAttribute(FilaTrash.originAttribute, at: path)
                    }
                    guard let origin = String(data: data, encoding: .utf8), wanted.contains(origin) else { continue }
                    // Ambiguous records must never pick an arbitrary file.
                    guard found[origin] == nil else { throw FilaFailure(code: .invalidRequest, path: path) }
                    found[origin] = path
                } catch let failure as FilaFailure where failure.systemError == ENOATTR || failure.code == .notFound {
                    continue
                }
            }
        }
        return found
    }

    /// Put Back from inside the trash: each item goes to the path the job
    /// wrote on it (`FilaTrash.originAttribute`), and the note comes off once
    /// it is home. An item without the note fails with `ENOATTR` naming it —
    /// the daemon's own answer for a missing attribute, kept distinct from a
    /// link that dropped so the app does not call a disconnect "no record".
    ///
    /// `started` receives each restore in turn: the items go home one at a
    /// time, and a cross-volume one is a whole copy of the file.
    func putBack(trashed paths: [String], started: ((UInt64) -> Void)? = nil) async throws {
        // One item's refusal is no reason to leave the rest in the trash: every
        // item is tried, and the first refusal is what the caller hears about.
        var firstFailure: Error?
        for path in paths {
            do {
                let data = try await session.perform(retryOnDisconnect: true) {
                    try await $0.extendedAttribute(FilaTrash.originAttribute, at: path)
                }
                guard let origin = String(data: data, encoding: .utf8), origin.hasPrefix("/") else {
                    throw FilaFailure(code: .operationFailed, systemError: ENOATTR, path: path)
                }
                try await restore(path, to: origin, started: started)
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }

    private func restore(
        _ path: String,
        to original: String,
        identity: UUID? = nil,
        started: ((UInt64) -> Void)? = nil
    ) async throws {
        let outcome = try await awaitJob(
            JobRequest(
                kind: .restore,
                sources: [path],
                destination: (original as NSString).deletingLastPathComponent,
                trashID: identity
            ),
            kind: .move,
            subtitle: Self.describe([path], destination: original),
            feedback: .silent,
            started: started
        )
        guard outcome.code == .success else { throw outcome }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
