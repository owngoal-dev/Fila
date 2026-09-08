@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

@Suite("Archive names")
struct ArchivePathTests {
    /// The one test in this file that is not about libarchive. Everything else
    /// here can be fixed by a library upgrade; this cannot, because the library
    /// deliberately hands back the name the archive declared and leaves the
    /// decision to whoever is about to join it to a directory.
    @Test("A name that could land a write outside the destination is refused, not repaired")
    func refusesHostileNames() {
        #expect(ArchivePath.validated("../escape") == nil)
        #expect(ArchivePath.validated("../../../../etc/passwd") == nil)
        #expect(ArchivePath.validated("/System/Library/x") == nil)
        #expect(ArchivePath.validated("a/b/../../../c") == nil)
        // Harmless on its own — it resolves to `b`. Still refused: an earlier
        // entry may have created `a` as a symlink, and `a/../b` then resolves
        // wherever that link points.
        #expect(ArchivePath.validated("a/../b") == nil)
        #expect(ArchivePath.validated("..") == nil)
        #expect(ArchivePath.validated("") == nil)
        #expect(ArchivePath.validated("/") == nil)
    }

    /// Both halves of the two-step attack are perfectly ordinary names, which is
    /// exactly why the name check cannot be the whole defence: an archive can
    /// carry `pwn` as a symlink to somewhere else entirely and then `pwn/loot`,
    /// and only something that remembers what it just created can see it. That
    /// memory lives in the extractor, not here.
    @Test("A link and a name nested under it are both legal names, so the check cannot end here")
    func acceptsBothHalvesOfALinkNesting() {
        #expect(ArchivePath.validated("pwn") == "pwn")
        #expect(ArchivePath.validated("pwn/loot") == "pwn/loot")
    }

    @Test("An ordinary name survives, tidied")
    func keepsOrdinaryNames() {
        #expect(ArchivePath.validated("./a/./b") == "a/b")
        #expect(ArchivePath.validated("nested//deeper/") == "nested/deeper")
        #expect(ArchivePath.validated("top.txt") == "top.txt")
        // Two dots at the front of a name are not a traversal; plenty of real
        // files start that way.
        #expect(ArchivePath.validated("..hidden") == "..hidden")
    }
}

@Suite("Zip")
struct ZipTests {
    @Test("A zip written here reads back with its tree, its modes and its symlink")
    func roundTrip() throws {
        try withScratch { scratch in
            let payload = samplePayload(byteCount: 300_000)
            let source = scratch.appendingPathComponent("payload.bin")
            try payload.write(to: source)

            let archive = scratch.appendingPathComponent("out.zip")
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addDirectory("nested/deeper", modified: stamp)
                try withDescriptor(reading: source) { input in
                    try writer.addFile("nested/deeper/payload.bin", from: input, mode: S_IFREG | 0o755, modified: stamp)
                }
                try writer.addSymbolicLink("nested/link", target: "deeper/payload.bin", modified: stamp)
                try writer.addData("top.txt", Data("hello".utf8), modified: stamp)
                try writer.finish()
            }

            // Deflate has to have done something, or the writer is storing.
            let archiveByteCount = try FileManager.default
                .attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0
            #expect(archiveByteCount < payload.count)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.map(\.declaredPath) == ["nested/deeper/", "nested/deeper/payload.bin", "nested/link", "top.txt"])

            let directory = entries[0]
            #expect(directory.kind == .directory)
            #expect(directory.modified == stamp)
            #expect(directory.relativePath == "nested/deeper")

            let file = entries[1]
            #expect(file.kind == .regular)
            #expect(file.mode & 0o777 == 0o755)
            #expect(file.byteCount == 300_000)

            #expect(entries[2].kind == .symbolicLink)
            #expect(entries[2].linkTarget == "deeper/payload.bin")

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                #expect(try reader.next()?.declaredPath == "nested/deeper/")
                #expect(try reader.next()?.declaredPath == "nested/deeper/payload.bin")
                #expect(try reader.data(maximumByteCount: 1 << 20) == payload)
                #expect(try reader.next()?.declaredPath == "nested/link")
                #expect(try reader.next()?.declaredPath == "top.txt")
                #expect(try String(decoding: reader.data(), as: UTF8.self) == "hello")
                #expect(try reader.next() == nil)
            }
        }
    }

    @Test("An entry named ../../etc/passwd is listed and refused, because that is how an extractor writes into /System")
    func refusesToEscape() throws {
        try withScratch { scratch in
            // The fixture is written with legal names of the same length and
            // then patched, because the writer refuses to record a name that
            // climbs out. What is under test is the *reader*: an archive
            // somebody else built is where such a name actually comes from.
            let archive = scratch.appendingPathComponent("hostile.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("xx/xx/etc/passwd", Data("owned".utf8))
                try writer.addData("Xabsolute", Data("owned".utf8))
                try writer.finish()
            }

            var bytes = try Data(contentsOf: archive)
            bytes.replaceEvery("xx/xx/etc/passwd", with: "../../etc/passwd")
            bytes.replaceEvery("Xabsolute", with: "/absolute")
            try bytes.write(to: archive)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.count == 2)
            #expect(entries[0].declaredPath == "../../etc/passwd")
            // Listed, so the user can see what is in the file they downloaded —
            // and with no relative path, so nothing can join it to a directory.
            #expect(entries.allSatisfy { $0.relativePath == nil })
        }
    }

    @Test("A name that is not UTF-8 lists with the bad bytes replaced and still extracts")
    func toleratesNamesThatAreNotUTF8() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("mojibake.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("aXb.txt", Data("hello".utf8))
                try writer.finish()
            }

            var bytes = try Data(contentsOf: archive)
            bytes.replaceEvery("aXb.txt", with: Data([0x61, 0xFF, 0x62, 0x2E, 0x74, 0x78, 0x74]))
            try bytes.write(to: archive)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            let entry = try #require(entries.first)
            // U+FFFD only ever stands in for a byte above 0x7F, so it cannot
            // manufacture a separator or a `..` — the name stays extractable.
            #expect(entry.declaredPath.contains("\u{FFFD}"))
            #expect(entry.relativePath != nil)
        }
    }

    /// The failure this guards against does not show up as a wrong answer, it
    /// shows up as an abort: freeing the libarchive handle in a throwing
    /// initialiser *and* in `deinit` frees it twice. Repeated, because a double
    /// free is only reliably fatal once the allocator reuses the block.
    @Test("An initialiser that fails frees its handle exactly once")
    func survivesAFailedOpen() {
        for _ in 0 ..< 500 {
            // `archive_write_open_fd` stats the descriptor, so -1 fails it.
            #expect(throws: (any Error).self) { try ArchiveWriter(descriptor: -1, format: .zip) }
            #expect(throws: (any Error).self) { try ArchiveReader(descriptor: -1) }
        }
    }

    @Test("An empty archive is still a zip")
    func writesAnEmptyArchive() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("empty.zip")
            try withDescriptor(writing: archive) { try ArchiveWriter(descriptor: $0, format: .zip).finish() }
            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.isEmpty)
        }
    }

    @Test("A progress handler that says stop stops, on both sides")
    func cancels() throws {
        try withScratch { scratch in
            let source = scratch.appendingPathComponent("payload.bin")
            try samplePayload(byteCount: 400_000).write(to: source)
            let archive = scratch.appendingPathComponent("cancelled.zip")

            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try withDescriptor(reading: source) { input in
                    #expect(throws: FormatFailure.cancelled) {
                        try writer.addFile("payload.bin", from: input) { done, _ in done < 100_000 }
                    }
                }
            }

            let whole = scratch.appendingPathComponent("whole.zip")
            try withDescriptor(writing: whole) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try withDescriptor(reading: source) { try writer.addFile("payload.bin", from: $0) }
                try writer.finish()
            }
            try withDescriptor(reading: whole) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                _ = try reader.next()
                #expect(throws: FormatFailure.cancelled) {
                    try reader.read(progress: { done, _ in done < 100_000 }) { _, _ in }
                }
            }
        }
    }

    @Test("Corruption fails loudly rather than extracting the wrong bytes")
    func detectsCorruption() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("corrupt.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("payload.bin", samplePayload(byteCount: 4096))
                try writer.finish()
            }

            // Well inside the deflated payload, past every header.
            var bytes = try Data(contentsOf: archive)
            bytes[200] ^= 0xFF
            try bytes.write(to: archive)

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                _ = try reader.next()
                #expect(throws: FormatFailure.self) { try reader.data() }
            }
        }
    }

    /// libarchive's `raw` format bids on anything at all, so without the check
    /// in `next()` every file in the filesystem would list as an archive of one
    /// nameless member — including the plist the browser was sent to by a wrong
    /// guess about an extension.
    /// A stored member, written by `/usr/bin/zip -0`, so its bytes are its
    /// content: flipping one corrupts the member without touching a deflate
    /// stream, which is the only way to reach the CRC check on its own.
    private static let storedZip = """
    UEsDBAoAAAAAAAsbJV0/7PdJFAAAABQAAAAKAAAAbWVtYmVyLnR4dHRoZSBxdWljayBicm93biBm
    b3gKUEsBAh4DCgAAAAAACxslXT/s90kUAAAAFAAAAAoAAAAAAAAAAAAAAKSBAAAAAG1lbWJlci50
    eHRQSwUGAAAAAAEAAQA4AAAAPAAAAAAA
    """

    /// The checksum is the only thing standing between a member whose bytes
    /// decode perfectly well and a member whose bytes are wrong. The hand-written
    /// reader this replaced verified CRC-32 itself; this pins that libarchive
    /// does too, and that the result reaches the caller as a failure rather than
    /// as content.
    @Test("A member whose checksum does not match fails instead of extracting the wrong bytes")
    func refusesAMemberThatFailsItsChecksum() throws {
        try withScratch { scratch in
            let good = try #require(Data(base64Encoded: Self.storedZip, options: .ignoreUnknownCharacters))
            let archive = scratch.appendingPathComponent("stored.zip")

            try good.write(to: archive)
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                _ = try reader.next()
                #expect(try String(decoding: reader.data(), as: UTF8.self) == "the quick brown fox\n")
            }

            var corrupt = good
            corrupt.replaceEvery("quick", with: "quack")
            try corrupt.write(to: archive)
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                _ = try reader.next()
                #expect(throws: FormatFailure.self) { try reader.data() }
            }
        }
    }

    @Test("Something that is not an archive is not recognised")
    func rejectsOtherFiles() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("random.bin")
            try samplePayload(byteCount: 4096).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                #expect(throws: FormatFailure.notRecognised) { try ArchiveReader.list(descriptor: descriptor) }
            }

            let text = scratch.appendingPathComponent("boot.plist")
            try Data("<?xml version=\"1.0\"?><plist/>".utf8).write(to: text)
            try withDescriptor(reading: text) { descriptor in
                #expect(throws: FormatFailure.notRecognised) { try ArchiveReader.list(descriptor: descriptor) }
            }
        }
    }
}

@Suite("Tar")
struct TarTests {
    @Test("An explicit archive root is hidden without changing child member positions")
    func rootDirectoryEntry() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("control.tar.gz")
            // USTAR fixture made with Python tarfile: ./, ./control, .config/.
            // Fila's writer deliberately never emits a redundant root entry.
            let fixture = "H4sIAAAAAAAC/+3VPQrDMAyGYc09hU+QOMY/0FP0CiYkIbQ04DrQ49dkDC20g7vkfRZp0/AhqWmlOl0E57Za7Oub3nfaiHLyB+sjx1RGyjE1bb/cc1pulfP31n7O33S7/IMNXpQm/+ousb/GaTircX7mNQ0nwaH2v6z/OE9Vv8Dv9z+YoLn/AAAAAAAAAAAAAAAA33gBvOynjgAoAAA="
            try #require(Data(base64Encoded: fixture)).write(to: archive)
            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries[0].isRootDirectory)
            let visible = entries.enumerated().filter { !$0.element.isRootDirectory }
            #expect(visible.map(\.offset) == [1, 2])
            #expect(visible.map(\.element.relativePath) == ["control", ".config"])
            #expect(ArchivePath.extractionFolderName(for: archive.lastPathComponent) == "control")
            #expect(ArchivePath.extractionFolderName(for: "control.tar.zst") == "control")
            #expect(ArchivePath.extractionFolderName(for: "Release.1.TAR.XZ") == "Release.1")
            #expect(ArchivePath.extractionFolderName(for: "notes.txt.gz") == "notes.txt")
        }
    }

    @Test("A tar written here reads back with its tree, its modes and its symlink")
    func roundTrip() throws {
        try withScratch { scratch in
            let payload = samplePayload(byteCount: 200_000)
            let source = scratch.appendingPathComponent("payload.bin")
            try payload.write(to: source)

            let archive = scratch.appendingPathComponent("out.tar")
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            // Past ustar's hundred bytes, so it has to go out as a pax record.
            let longPath = "nested/" + String(repeating: "deep/", count: 30) + "payload.bin"

            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addDirectory("nested", modified: stamp)
                try withDescriptor(reading: source) { input in
                    try writer.addFile("nested/payload.bin", from: input, mode: 0o755, modified: stamp)
                }
                try writer.addSymbolicLink("nested/link", target: "payload.bin", modified: stamp)
                try writer.addData(longPath, Data("deep".utf8), modified: stamp)
                try writer.finish()
            }

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.map(\.declaredPath) == ["nested/", "nested/payload.bin", "nested/link", longPath])
            #expect(entries[0].kind == .directory)
            #expect(entries[0].modified == stamp)
            #expect(entries[1].mode & 0o777 == 0o755)
            #expect(entries[1].byteCount == 200_000)
            #expect(entries[2].kind == .symbolicLink)
            #expect(entries[2].linkTarget == "payload.bin")

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                while let entry = try reader.next() {
                    guard entry.declaredPath == "nested/payload.bin" else { continue }
                    #expect(try reader.data(maximumByteCount: 1 << 20) == payload)
                }
            }
        }
    }

    /// The extractor runs its writes through a daemon that is root. An archive
    /// that can plant a setuid-root binary just by being unpacked is a root
    /// shell for whoever built it, so the bit is recorded but never handed on.
    @Test("A setuid bit survives into the listing and not out of it")
    func stripsSetuidFromThePermissionsAnExtractorApplies() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("hostile.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addData("payload", Data("owned".utf8), mode: 0o4755)
                try writer.finish()
            }

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            let entry = try #require(entries.first)
            #expect(entry.mode & 0o7777 == 0o4755)
            #expect(entry.permissions == 0o755)
        }
    }

    /// `time_t(someDouble)` traps outside `time_t`'s range, and mtimes come off a
    /// filesystem people edit as root. A nonsense one has to produce a nonsense
    /// timestamp, not a crash.
    @Test("An impossible modification time is clamped rather than trapped", arguments: [
        Date(timeIntervalSince1970: 1e300),
        Date(timeIntervalSince1970: -1e300),
        Date.distantFuture,
        Date.distantPast,
    ])
    func survivesAnImpossibleTimestamp(stamp: Date) throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("stamped.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try writer.addData("payload", Data("x".utf8), modified: stamp)
                try writer.finish()
            }
            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.count == 1)
        }
    }

    @Test("A member streams into a descriptor without ever being held in memory")
    func streamsIntoADescriptor() throws {
        try withScratch { scratch in
            let payload = samplePayload(byteCount: 500_000)
            let source = scratch.appendingPathComponent("payload.bin")
            try payload.write(to: source)

            let archive = scratch.appendingPathComponent("out.tar")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tar)
                try withDescriptor(reading: source) { try writer.addFile("payload.bin", from: $0) }
                try writer.finish()
            }

            let extracted = scratch.appendingPathComponent("extracted.bin")
            try withDescriptor(reading: archive) { input in
                let reader = try ArchiveReader(descriptor: input)
                _ = try reader.next()
                let written = try withDescriptor(writing: extracted) { try reader.read(into: $0) }
                #expect(written == 500_000)
            }
            #expect(try Data(contentsOf: extracted) == payload)
        }
    }

    @Test("A tar.gz is read straight through, with no scratch file in between")
    func readsACompressedTar() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("data.tar.gz")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tarGzip)
                try writer.addDirectory("usr/libexec")
                try writer.addData("usr/libexec/filad", samplePayload(byteCount: 90000))
                try writer.finish()
            }
            // The whole reason the gzip ceiling could go: browsing this never
            // expands it to anything but a 64 KB window.
            let byteCount = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0
            #expect(byteCount < 90000)

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                #expect(try reader.next()?.declaredPath == "usr/libexec/")
                #expect(try reader.next()?.declaredPath == "usr/libexec/filad")
                #expect(try reader.data(maximumByteCount: 1 << 20) == samplePayload(byteCount: 90000))
            }
        }
    }

    @Test("A tar.xz round trips, which is what iOS repositories ship")
    func readsAnXzTar() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("data.tar.xz")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tarXz)
                try writer.addData("control", Data("Package: wiki.qaq.fila\n".utf8))
                try writer.finish()
            }
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                #expect(try reader.next()?.declaredPath == "control")
                #expect(try String(decoding: reader.data(), as: UTF8.self) == "Package: wiki.qaq.fila\n")
            }
        }
    }

    /// A tar written by the system `tar`, holding a hard link and a symlink.
    ///
    /// Hard links are the reason this fixture is checked in rather than
    /// generated: libarchive's writer here has no way to emit one, and what the
    /// reader reports for one is a decision the extractor depends on.
    private static let hardLinkTarGzip = """
    H4sIAAgFm2oAA+2UQQrDIBBFXfcUc4Iyo6M5jzTShAZD1NIevyZQaDahhZou6tt8xFl8/fwZQ3/u
    vR2O6Z5EIRDRMMOsjdGLZp6aoQZISzYGJRMCklJMArCUoVeuMdmQrUx22py7dc4NG/frR8FXPRYk
    dja4Fk6jT86nw6/tVHYmuhx9W7L9b/Q/H9b914pZAI07LKc/7//Q+0vZ9JevabT+KH9UUoCs+Vcq
    lUoxHqlLW1gADAAA
    """

    @Test("A hard link is reported as one, so an extractor can refuse it")
    func reportsHardLinks() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("hardlink.tar.gz")
            try #require(Data(base64Encoded: Self.hardLinkTarGzip, options: .ignoreUnknownCharacters))
                .write(to: archive)

            let entries = try withDescriptor(reading: archive) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.map(\.declaredPath) == ["original.txt", "second.txt", "link.txt"])
            #expect(entries[0].hardLinkTarget == nil)
            // A second name for a file that already exists, with no bytes of its
            // own. The app refuses to create one: letting an archive choose the
            // existing file is letting it choose what gets written.
            #expect(entries[1].hardLinkTarget == "original.txt")
            #expect(entries[2].kind == .symbolicLink)
            #expect(entries[2].linkTarget == "original.txt")
        }
    }
}

@Suite("Formats libarchive brought with it")
struct ForeignFormatTests {
    /// Written by the 7-Zip command line, not by libarchive, so this is
    /// interoperability rather than a round trip.
    private static let sevenZip = """
    N3q8ryccAAQSQjTrpAAAAAAAAAAhAAAAAAAAAB6jl4oBACRQYWNrYWdlOiB3aWtpLnFhcS5maWxh
    CmhlbGxvIGZyb20gN3oKAAAAgTMHrg/QluR8nz9HQQQPcQz8Nkp4V/AIiTp2/4P5IH+c5wpcRys0
    JEPgvtrKM7MCzetIzaHBMp3RPA1zSGxQMXjiu6tXyProJgZSOOck7cvjU+boY9Mq0TssDWwQgYSN
    OQYgdaFrwpYURJLe5HSgeHdN3/oTt6AAABcGKQEJewAHCwEAASMDAQEFXQAQAAAMgKIKASb8Q84A
    AA==
    """

    @Test("A 7z reads, which nothing hand-written here was ever going to do")
    func readsSevenZip() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("fixture.7z")
            try #require(Data(base64Encoded: Self.sevenZip, options: .ignoreUnknownCharacters)).write(to: archive)

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                var contents: [String: String] = [:]
                var members: [String: ArchiveEntry] = [:]
                while let entry = try reader.next() {
                    // Keyed on the extractable form, so a directory's trailing
                    // slash does not become part of its name.
                    let name = try #require(entry.relativePath)
                    members[name] = entry
                    guard entry.kind == .regular else { continue }
                    contents[name] = try String(decoding: reader.data(), as: UTF8.self)
                }
                #expect(contents["control"] == "Package: wiki.qaq.fila\n")
                #expect(contents["nested/inner.txt"] == "hello from 7z\n")
                // Type bits and permissions both, and never a mode of zero: a
                // file extracted with one is a file nobody can open.
                let directory = try #require(members["nested"])
                #expect(directory.kind == .directory)
                #expect(directory.mode & S_IFMT == S_IFDIR)
                #expect(try #require(members["control"]).mode & S_IFMT == S_IFREG)
                #expect(members.values.allSatisfy { $0.mode & 0o777 != 0 })
            }
        }
    }

    /// `gzip -9 -n`, so there is no stored name and the reader has to fall back
    /// to the file's own.
    private static let lonelyGzip = "H4sIAAAAAAACAwtITM5OTE+1UijPzM7UK0ws1EvLzEnkCkstKs7Mz7NSMNQz4AIAgpAVfiQAAAA="

    @Test("A gzip that wraps a plain file lists as its one member")
    func readsALoneGzip() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("payload.txt.gz")
            try #require(Data(base64Encoded: Self.lonelyGzip, options: .ignoreUnknownCharacters)).write(to: archive)

            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor, name: "payload.txt.gz")
                let entry = try #require(try reader.next())
                #expect(entry.declaredPath == "payload.txt")
                // The format records no length. Saying so beats inflating a
                // gigabyte to fill in a column, which is what the old reader's
                // 256 MB ceiling was there to survive.
                #expect(entry.byteCount == nil)
                #expect(try String(decoding: reader.data(), as: UTF8.self) == "Package: wiki.qaq.fila\nVersion: 1.0\n")
            }
        }
    }

    @Test("An oversized member is refused before it is allocated, size in the header or not")
    func refusesToAllocateForALargeMember() throws {
        try withScratch { scratch in
            let archive = scratch.appendingPathComponent("payload.txt.gz")
            try #require(Data(base64Encoded: Self.lonelyGzip, options: .ignoreUnknownCharacters)).write(to: archive)
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor, name: "payload.txt.gz")
                _ = try reader.next()
                #expect(throws: FormatFailure.self) { try reader.data(maximumByteCount: 8) }
            }
        }
    }
}

@Suite("ar")
struct ArTests {
    /// A `.deb` is three `ar` members and nothing else, so the fixture is the
    /// real shape rather than a simplification of it. Built by hand because
    /// libarchive's `ar` writer is not one of the formats this app writes.
    private func debian(_ members: [(String, Data)]) -> Data {
        var archive = Data("!<arch>\n".utf8)
        for (name, payload) in members {
            func field(_ text: String, _ width: Int) -> Data {
                Data(text.padding(toLength: width, withPad: " ", startingAt: 0).utf8)
            }
            archive += field(name, 16)
            archive += field("1700000000", 12)
            archive += field("0", 6)
            archive += field("0", 6)
            archive += field("100644", 8)
            archive += field("\(payload.count)", 10)
            archive += Data("`\n".utf8)
            archive += payload
            if payload.count % 2 == 1 {
                archive += Data([0x0A])
            }
        }
        return archive
    }

    @Test("A .deb lists its members, and the control tarball opens through a second reader")
    func readsADeb() throws {
        try withScratch { scratch in
            let control = scratch.appendingPathComponent("control.tar.gz")
            try withDescriptor(writing: control) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .tarGzip)
                try writer.addData("control", Data("Package: wiki.qaq.fila\nVersion: 1.0\n".utf8))
                try writer.finish()
            }
            let controlBytes = try Data(contentsOf: control)

            let package = scratch.appendingPathComponent("fila.deb")
            try debian([
                ("debian-binary", Data("2.0\n".utf8)),
                ("control.tar.gz", controlBytes),
                ("data.tar", Data(repeating: 0, count: 1024)),
            ]).write(to: package)

            let entries = try withDescriptor(reading: package) { try ArchiveReader.list(descriptor: $0) }
            #expect(entries.map(\.declaredPath) == ["debian-binary", "control.tar.gz", "data.tar"])
            #expect(entries.allSatisfy { $0.kind == .regular })
            #expect(entries[0].mode & 0o777 == 0o644)

            // What the browser does to descend: pull the member out to a file of
            // its own, then open a second reader on that descriptor. The gzip in
            // the middle needs no step of its own any more.
            let extracted = scratch.appendingPathComponent("extracted.tar.gz")
            try withDescriptor(reading: package) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                while let entry = try reader.next() {
                    guard entry.declaredPath == "control.tar.gz" else { continue }
                    try withDescriptor(writing: extracted) { try reader.read(into: $0) }
                }
            }
            try withDescriptor(reading: extracted) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                #expect(try reader.next()?.declaredPath == "control")
                #expect(try String(decoding: reader.data(), as: UTF8.self) == "Package: wiki.qaq.fila\nVersion: 1.0\n")
            }
        }
    }
}

extension Data {
    /// Replaces every occurrence of `needle` with `replacement`, which must be
    /// the same length — the fixtures here patch names into archives whose
    /// length fields would otherwise all have to be rewritten.
    mutating func replaceEvery(_ needle: String, with replacement: String) {
        replaceEvery(needle, with: Data(replacement.utf8))
    }

    mutating func replaceEvery(_ needle: String, with replacement: Data) {
        let pattern = Data(needle.utf8)
        precondition(pattern.count == replacement.count, "the patch has to be the same length")
        var index = startIndex
        while index + pattern.count <= endIndex {
            if self[index ..< index + pattern.count] == pattern {
                replaceSubrange(index ..< index + pattern.count, with: replacement)
                index += pattern.count
            } else {
                index += 1
            }
        }
    }
}

@Suite("Compression choices", .serialized)
struct CompressionChoiceTests {
    @Test("Every offered writer round trips file content and a directory")
    func offeredFormats() throws {
        // Sequential: maximum compression codecs own large dictionaries.
        for format in ArchiveFormat.allCases {
            try withScratch { scratch in
                let archive = scratch.appendingPathComponent("roundtrip." + format.filenameExtension)
                let payload = samplePayload(byteCount: 32000)
                try withDescriptor(writing: archive) { descriptor in
                    let writer = try ArchiveWriter(descriptor: descriptor, format: format)
                    try writer.addDirectory("folder")
                    try writer.addData("folder/data.bin", payload, mode: 0o755)
                    try writer.finish()
                }
                try withDescriptor(reading: archive) { descriptor in
                    let reader = try ArchiveReader(descriptor: descriptor)
                    var sawFile = false
                    var sawDirectory = false
                    while let entry = try reader.next() {
                        if entry.kind == .directory {
                            sawDirectory = true
                        }
                        if entry.relativePath == "folder/data.bin" {
                            sawFile = true
                            #expect(try reader.data() == payload, "\(format)")
                        }
                    }
                    #expect(sawFile && sawDirectory, "\(format)")
                }
            }
        }
    }

    @Test("ZIP choices produce the declared storage method and readable data")
    func zipModes() throws {
        for mode in ZipCompression.allCases {
            try withScratch { scratch in
                let archive = scratch.appendingPathComponent("mode.zip")
                let payload = samplePayload(byteCount: 60000)
                try withDescriptor(writing: archive) { descriptor in
                    let writer = try ArchiveWriter(descriptor: descriptor, zipCompression: mode)
                    try writer.addData("data.bin", payload)
                    try writer.finish()
                }
                let bytes = try Data(contentsOf: archive)
                // The local ZIP header carries method as little-endian UInt16.
                #expect(Array(bytes.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
                #expect(bytes[8] == (mode == .store ? 0 : 8))
                #expect(bytes[9] == 0)
                try withDescriptor(reading: archive) { descriptor in
                    let reader = try ArchiveReader(descriptor: descriptor)
                    _ = try reader.next()
                    #expect(try reader.data() == payload)
                }
            }
        }
    }
}
