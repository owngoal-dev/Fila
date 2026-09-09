import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

/// `removeNode`: one node, never a tree, and only the kind the caller
/// verified.
@Suite("Removing one node")
struct RemoveNodeTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test("A file is unlinked and an empty directory is removed")
    func removesWhatItWasToldTo() throws {
        let file = scratch.file("one.txt")
        try operations.removeNode(at: file, directory: false)
        #expect(!exists(file))

        let directory = scratch.directory("empty")
        try operations.removeNode(at: directory, directory: true)
        #expect(!exists(directory))
    }

    @Test("A directory with entries is refused and keeps every entry")
    func refusesNonEmptyDirectory() {
        scratch.directory("full")
        scratch.file("full/keep.txt")
        let failure = #expect(throws: FilaFailure.self) {
            try operations.removeNode(at: scratch.path("full"), directory: true)
        }
        #expect(failure?.systemError == ENOTEMPTY)
        #expect(exists(scratch.path("full/keep.txt")))
    }

    @Test("A name whose kind is not the one verified is left alone")
    func refusesTheWrongKind() {
        scratch.directory("folder")
        scratch.file("plain.txt")
        // Verified as a file, found a directory: the kernel refuses unlink.
        let asFile = #expect(throws: FilaFailure.self) {
            try operations.removeNode(at: scratch.path("folder"), directory: false)
        }
        #expect(asFile?.systemError == EPERM || asFile?.systemError == EISDIR)
        #expect(exists(scratch.path("folder")))
        // Verified as a directory, found a file: rmdir refuses.
        let asDirectory = #expect(throws: FilaFailure.self) {
            try operations.removeNode(at: scratch.path("plain.txt"), directory: true)
        }
        #expect(asDirectory?.systemError == ENOTDIR)
        #expect(exists(scratch.path("plain.txt")))
    }

    @Test("Removing a link removes the link and keeps its target")
    func neverFollowsLinks() throws {
        let target = scratch.file("target.txt", contents: "kept")
        let link = scratch.path("pointer")
        #expect(symlink(target, link) == 0)
        try operations.removeNode(at: link, directory: false)
        #expect(metadata(of: link) == nil)
        #expect(metadata(of: target)?.st_size == 4)

        scratch.directory("realdir")
        let directoryLink = scratch.path("dirpointer")
        #expect(symlink(scratch.path("realdir"), directoryLink) == 0)
        // A link to a directory is still a link: it goes as a non-directory.
        try operations.removeNode(at: directoryLink, directory: false)
        #expect(metadata(of: directoryLink) == nil)
        #expect(exists(scratch.path("realdir")))
    }

    @Test("The guard refuses a protected node")
    func guardStillApplies() {
        let failure = #expect(throws: FilaFailure.self) {
            try operations.removeNode(at: "/", directory: true)
        }
        #expect(failure?.code == .protectedPath)
    }
}
