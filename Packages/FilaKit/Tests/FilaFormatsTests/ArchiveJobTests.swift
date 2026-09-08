import FilaFileOps
@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

/// The job as the helper and the in-process backend run it: real files, real
/// descriptors, the same `FileOperations` the daemon uses.
@Suite("Archive jobs", .serialized)
struct ArchiveJobTests {
    private let operations = FileOperations(bootstrapRoot: "")

    private func run(_ request: JobRequest) -> (outcome: FilaFailure, progress: [JobProgress], notes: [String]) {
        var progress: [JobProgress] = []
        var notes: [String] = []
        let outcome = ArchiveJob(request: request, operations: operations).run { progress.append($0) } note: { notes.append($0) }
        return (outcome, progress, notes)
    }

    @Test("Selected extraction finishes without scanning unrelated entries past the listing limit")
    func selectedExtractionStopsAfterSelection() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("many.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addData("selected.txt", Data("selected".utf8))
                for index in 1 ... ArchiveReader.maximumEntryCount {
                    try writer.addData("other-\(index)", Data())
                }
                try writer.finish()
            }
            let destination = scratch.appendingPathComponent("out")
            let result = run(JobRequest(
                kind: .extract, sources: [archive.path], destination: destination.path,
                archive: ArchiveOptions(members: [ArchiveSelection(index: 0, declaredPath: "selected.txt")])
            ))
            #expect(result.outcome.code == .success)
            #expect(try String(contentsOf: destination.appendingPathComponent("selected.txt"), encoding: .utf8) == "selected")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["selected.txt"])
        }
    }

    private func makeTree(in scratch: URL) throws -> URL {
        let tree = scratch.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try samplePayload(byteCount: 200_000).write(to: tree.appendingPathComponent("nested/payload.bin"))
        try Data("hello".utf8).write(to: tree.appendingPathComponent("top.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("top.txt").path)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "top.txt")
        return tree
    }

    @Test("A tree compresses with totals and extracts back with its modes and its link")
    func roundTrip() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.zip")
            let compressed = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions()))
            #expect(compressed.outcome.code == .success)
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(compressed.progress.last?.itemsTotal == 5)
            #expect(compressed.progress.last?.bytesTotal == 200_005)
            #expect(compressed.progress.last?.fraction == 1)
            #expect(compressed.notes.isEmpty)

            let out = scratch.appendingPathComponent("out")
            let extracted = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions()))
            #expect(extracted.outcome.code == .success)
            #expect(try Data(contentsOf: out.appendingPathComponent("tree/nested/payload.bin")) == samplePayload(byteCount: 200_000))
            #expect(try String(contentsOf: out.appendingPathComponent("tree/top.txt"), encoding: .utf8) == "hello")
            let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("tree/top.txt").path)[.posixPermissions] as? Int
            #expect(mode == 0o755)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("tree/link").path) == "top.txt")
            // A leftover temporary is a half-written member nobody asked for.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("tree").path).filter { $0.hasPrefix(".fila-") }
            #expect(leftovers.isEmpty)
        }
    }

    @Test("Read-only folders receive all their children before archive modes are applied")
    func readOnlyDirectories() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("folders.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addDirectory("folder", mode: 0o555)
                try writer.addDirectory("folder/nested", mode: 0o555)
                try writer.addData("folder/nested/song.txt", Data("song".utf8), mode: 0o444)
                try writer.finish()
            }
            let out = scratch.appendingPathComponent("out")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appendingPathComponent("folder").path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appendingPathComponent("folder/nested").path)
            }
            let extracted = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, archive: ArchiveOptions()))
            #expect(extracted.outcome.code == .success)
            #expect(try Data(contentsOf: out.appendingPathComponent("folder/nested/song.txt")) == Data("song".utf8))
            #expect(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("folder/nested").path)[.posixPermissions] as? Int == 0o555)
            #expect(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("folder/nested/song.txt").path)[.posixPermissions] as? Int == 0o444)
        }
    }

    @Test("A password locks a zip, the wrong one is its own outcome, and the right one opens it")
    func password() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("locked.zip")
            let options = ArchiveOptions(format: .zip, encryption: .aes256, password: "secret")
            #expect(run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: options)).outcome.code == .success)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.first { $0.declaredPath == "tree/top.txt" }?.isEncrypted == true)

            let out = scratch.appendingPathComponent("out")
            for wrong in [nil, "wrong"] {
                let attempt = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(password: wrong)))
                #expect(attempt.outcome.code == .wrongPassword)
                #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("tree/top.txt").path))
            }
            let right = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(password: "secret")))
            #expect(right.outcome.code == .success)
            #expect(try String(contentsOf: out.appendingPathComponent("tree/top.txt"), encoding: .utf8) == "hello")
        }
    }

    @Test("A tar refuses a password rather than writing an archive that is not locked")
    func tarRefusesPassword() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.tar")
            let outcome = run(JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions(format: .tar, password: "secret"))).outcome
            #expect(outcome.code != .success)
            #expect(!FileManager.default.fileExists(atPath: archive.path))
        }
    }

    @Test("An escaping name is skipped and said, and the selection is matched by position")
    func hostileNamesAndSelection() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("hostile.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("xx/xx/etc/passwd", Data("owned".utf8))
                try writer.addData("safe.txt", Data("fine".utf8))
                try writer.addData("unwanted.txt", Data("no".utf8))
                try writer.finish()
            }
            var bytes = try Data(contentsOf: archive)
            bytes.replaceEvery("xx/xx/etc/passwd", with: "../../etc/passwd")
            try bytes.write(to: archive)

            let out = scratch.appendingPathComponent("out")
            let members = [ArchiveSelection(index: 0, declaredPath: "../../etc/passwd"), ArchiveSelection(index: 1, declaredPath: "safe.txt")]
            let result = run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, overwrite: true, archive: ArchiveOptions(members: members)))
            #expect(result.outcome.code == .success)
            #expect(result.notes.count == 1)
            #expect(result.notes.first?.contains("outside the destination") == true)
            #expect(try String(contentsOf: out.appendingPathComponent("safe.txt"), encoding: .utf8) == "fine")
            #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("unwanted.txt").path))
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("etc/passwd").path))

            // The same position naming a different member is the archive
            // having changed: skipped, never handed over.
            let stale = run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.appendingPathComponent("stale").path, overwrite: true, archive: ArchiveOptions(members: [ArchiveSelection(index: 2, declaredPath: "safe.txt")])))
            #expect(stale.outcome.code == .success)
            #expect(stale.notes.first?.contains("changed") == true)
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("stale/unwanted.txt").path))
        }
    }

    @Test("A cancelled compress leaves no archive and no temporary behind")
    func cancelledCompress() throws {
        try withScratch { scratch in
            let tree = try makeTree(in: scratch)
            let archive = scratch.appendingPathComponent("tree.zip")
            let job = ArchiveJob(request: JobRequest(kind: .compress, sources: [tree.path], destination: archive.path, archive: ArchiveOptions()), operations: operations)
            var cancelledOnce = false
            let outcome = job.run { _ in
                if !cancelledOnce {
                    cancelledOnce = true; job.cancel()
                }
            }
            #expect(outcome.code == .cancelled)
            let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0 != "tree" }
            #expect(left.isEmpty)
        }
    }
}
