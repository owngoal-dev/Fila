import FilaFileOps
@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

@Suite("Archive publication", .serialized)
struct ArchivePublicationTests {
    private func run(_ request: JobRequest) throws {
        var notes: [String] = []
        let result = ArchiveJob(request: request, operations: FileOperations(bootstrapRoot: ""))
            .run(report: { _ in }, note: { notes.append($0) })
        try #require(result.code == .success, "\(result), \(notes)")
    }

    @Test("Every offered format compresses and extracts Unicode files through the real job", arguments: ArchiveFormat.allCases)
    func formats(_ format: ArchiveFormat) throws {
        try withScratch { scratch in
            let folder = scratch.appendingPathComponent("歌曲 (测试)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let payload = samplePayload(byteCount: 200_000)
            try payload.write(to: folder.appendingPathComponent("张碧晨 🎵.m4a"))
            try Data().write(to: folder.appendingPathComponent("empty"))
            try Data("view settings".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
            try Data("keep".utf8).write(to: folder.appendingPathComponent(".hidden"))
            let archive = scratch.appendingPathComponent("Download." + format.filenameExtension)
            try run(JobRequest(kind: .compress, sources: [folder.path], destination: archive.path, archive: ArchiveOptions(format: format)))
            let out = scratch.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            try run(JobRequest(kind: .extract, sources: [archive.path], destination: out.path, archive: ArchiveOptions(organizeExtraction: true)))
            let restored = out.appendingPathComponent(folder.lastPathComponent)
            #expect(try Data(contentsOf: restored.appendingPathComponent("张碧晨 🎵.m4a")) == payload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: restored.path).sorted() == [".hidden", "empty", "张碧晨 🎵.m4a"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [folder.lastPathComponent])
        }
    }

    @Test("macOS grouping follows top-level items, including implicit folders", arguments: [
        ["song.txt"], ["Album/song.txt"], ["Album/one.txt", "Album/two.txt"], ["one.txt", "two.txt"],
        ["Album/nested/song.txt"], [".hidden"],
    ])
    func grouping(_ names: [String]) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("Download.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor)
                for name in names { try writer.addData(name, Data(name.utf8)) }
                try writer.addData(".DS_Store", Data("layout".utf8))
                try writer.addData("__MACOSX/.DS_Store", Data("layout".utf8))
                try writer.finish()
            }
            let roots = Set(names.map { String($0.split(separator: "/")[0]) })
            let parent = roots.count == 1 ? scratch : scratch.appendingPathComponent("Download")
            try run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path, archive: ArchiveOptions(organizeExtraction: true)))
            for name in names {
                #expect(try Data(contentsOf: parent.appendingPathComponent(name)) == Data(name.utf8))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == (["Download.zip"] + (roots.count == 1 ? Array(roots) : ["Download"])).sorted())
        }
    }

    @Test("Repeated extraction numbers files and folders without replacing or merging", arguments: [false, true])
    func collisions(_ directory: Bool) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("Download.zip")
            let name = directory ? "Album/song.txt" : "song.txt"
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor)
                try writer.addData(name, Data("song".utf8))
                try writer.finish()
            }
            let request = JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path, archive: ArchiveOptions(organizeExtraction: true))
            try run(request)
            try Data("original".utf8).write(to: scratch.appendingPathComponent(name))
            try run(request)
            #expect(try Data(contentsOf: scratch.appendingPathComponent(name)) == Data("original".utf8))
            #expect(try Data(contentsOf: scratch.appendingPathComponent(directory ? "Album 2/song.txt" : "song 2.txt")) == Data("song".utf8))
        }
    }

    @Test("Failed encrypted extraction leaves no result or workspace", arguments: ZipEncryption.allCases)
    func failedExtraction(_ encryption: ZipEncryption) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("Locked.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, encryption: encryption, password: "secret")
                try writer.addDirectory("Album")
                try writer.addData("Album/song.txt", Data("song".utf8))
                try writer.finish()
            }
            let result = ArchiveJob(
                request: JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path, archive: ArchiveOptions(password: "wrong", organizeExtraction: true)),
                operations: FileOperations(bootstrapRoot: "")
            ).run(report: { _ in })
            #expect(result.code == .wrongPassword)
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["Locked.zip"])
        }
    }

    @Test("Empty and metadata-only archives do not leave an empty wrapper", arguments: [false, true])
    func emptyArchive(_ metadata: Bool) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("Empty.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor)
                if metadata { try writer.addData("__MACOSX/.DS_Store", Data("layout".utf8)) }
                try writer.finish()
            }
            try run(JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path,
                               archive: ArchiveOptions(organizeExtraction: true)))
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["Empty.zip"])
        }
    }

    @Test("Cancellation leaves neither a published result nor a private workspace")
    func cancellation() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("Cancelled.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor)
                try writer.addData("Album/song", samplePayload(byteCount: 1_000_000))
                try writer.finish()
            }
            let job = ArchiveJob(
                request: JobRequest(kind: .extract, sources: [archive.path], destination: scratch.path,
                                    archive: ArchiveOptions(organizeExtraction: true)),
                operations: FileOperations(bootstrapRoot: "")
            )
            let result = job.run(report: { _ in job.cancel() })
            #expect(result.code == .cancelled)
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["Cancelled.zip"])
        }
    }
}
