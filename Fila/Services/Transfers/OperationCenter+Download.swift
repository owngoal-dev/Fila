import FilaClient
import FilaProtocol
import FilaRemote
import Foundation

/// Pulling a URL down to a directory.
///
/// It is an `OperationCenter` operation like a copy or a compress, deliberately:
/// it gets the same row, the same progress bar, the same stop button and the
/// same failure toast, because from the user's side it is the same kind of
/// thing — bytes arriving somewhere, slowly, with something that could go wrong.
extension OperationCenter {
    @discardableResult
    func download(_ url: URL, into directory: String) -> UUID {
        let name = URLDownload.suggestedName(for: url)
        return run(
            kind: .download,
            title: Kind.download.runningTitle,
            subtitle: name + " → " + directory,
            affected: [directory]
        ) { report in
            let staging = try await FileSession.shared.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }

            let file = try await URLDownload.fetch(url, into: staging) { progress in
                // `URLSession` reports from its own queue and the row lives on
                // the main actor.
                let update = JobProgress(
                    bytesDone: progress.received,
                    bytesTotal: max(0, progress.total),
                    itemsDone: 0,
                    itemsTotal: 0,
                    currentPath: progress.name
                )
                Task { @MainActor in report(update) }
            }
            try await Self.place(file, into: directory)
        }
    }

    /// Publishes from the workspace through a temporary beside the target.
    private static func place(_ file: URL, into directory: String) async throws {
        let session = FileSession.shared
        let temporary = (directory as NSString)
            .appendingPathComponent(".fila-tmp-\(UUID().uuidString)")
        let descriptor = try await session.perform {
            try await $0.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY, mode: 0o600)
        }
        // One cleanup for every way this can fail after the temporary exists —
        // the write, the rename, or running out of names. A leftover
        // `.fila-tmp-…` in a directory the user is looking at is the visible
        // half of the bug; the invisible half is that it holds the bytes.
        do {
            try await Task.detached { try DescriptorIO.copyAndClose(descriptor, from: file) }.value
            try await session.perform { try await $0.setAttributes(.newItemDefaults, at: temporary) }
            try await claim(temporary, named: file.lastPathComponent, in: directory)
        } catch {
            await session.discardTemporary(temporary)
            throw error
        }
    }

    /// Renames the temporary to the first free name, trying `name`, `name 2`,
    /// `name 3` and so on.
    ///
    /// Every attempt is an exclusive rename, so the name is not checked and
    /// then taken — the kernel does both under one lock. A plain `rename(2)`
    /// here would silently destroy whatever already had that name, which for
    /// "download this again" is the copy the user already had.
    private static func claim(_ temporary: String, named name: String, in directory: String) async throws {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        for attempt in 1 ... 64 {
            var candidate = attempt == 1 ? stem : "\(stem) \(attempt)"
            if !suffix.isEmpty {
                candidate += "." + suffix
            }
            do {
                let target = (directory as NSString).appendingPathComponent(candidate)
                try await FileSession.shared.perform {
                    try await $0.rename(temporary, to: target, exclusive: true)
                }
                return
            } catch let failure as FilaFailure where failure.systemError == EEXIST {
                continue
            }
        }
        throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: directory)
    }
}
