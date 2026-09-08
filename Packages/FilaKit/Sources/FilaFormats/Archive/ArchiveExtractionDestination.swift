import Darwin
import FilaFileOps
import FilaProtocol
import Foundation

/// A private sibling workspace, published only after every member succeeds.
/// A single top-level item keeps its own name; multiple items share one folder.
final class ArchiveExtractionDestination {
    let temporary: String
    private let directory: String
    private let operations: FileOperations

    init(directory: String, operations: FileOperations) throws {
        self.directory = try FilaPath.canonical(directory)
        self.operations = operations
        temporary = FilaPath.join(self.directory, ".fila-extract-\(UUID().uuidString)")
        try operations.create(.directory, at: temporary, mode: 0o700)
    }

    func publish(archiveName: String, checkCancelled: () throws -> Void) throws {
        let listing = try DirectoryListing(path: temporary)
        defer { listing.close() }
        let entries = try listing.nextPage(limit: 2).entries
        guard !entries.isEmpty else { return }
        let single = entries.count == 1 ? entries[0] : nil
        let source = single.map { FilaPath.join(temporary, $0.name) } ?? temporary
        let name = single?.name ?? ArchivePath.extractionFolderName(for: archiveName)
        let isDirectory = single?.kind == .directory || single == nil
        let suffix = isDirectory ? "" : (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        if single == nil {
            try operations.setAttributes(.newItemDefaults, at: temporary)
        }
        for index in 1 ... Int.max {
            try checkCancelled()
            let base = stem.isEmpty ? "Archive" : stem
            let numbered = index == 1 ? base : "\(base) \(index)"
            let candidate = numbered + (suffix.isEmpty ? "" : "." + suffix)
            do {
                try operations.rename(source, to: FilaPath.join(directory, candidate), exclusive: true)
                return
            } catch let failure as FilaFailure where failure.systemError == EEXIST {
                continue
            }
        }
        throw FilaFailure(errno: EEXIST, path: directory)
    }

    func discard() throws {
        try operations.discardTemporary(temporary)
    }
}
