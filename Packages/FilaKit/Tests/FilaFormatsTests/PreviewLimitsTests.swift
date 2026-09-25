@testable import FilaFormats
import FilaProtocol
import Foundation
import Testing

struct PreviewLimitsTests {
    @Test(arguments: [FileFormat.sqlite, .image, .pdf])
    func `Memory-backed previews accept the byte ceiling and reject one byte over`(format: FileFormat) throws {
        try PreviewLimits.validate(byteCount: PreviewLimits.fileByteCount, format: format)
        #expect(throws: FormatFailure.self) {
            try PreviewLimits.validate(byteCount: PreviewLimits.fileByteCount + 1, format: format)
        }
    }

    @Test
    func `Large archive browsing is bounded while media playback remains windowed`() throws {
        try PreviewLimits.validate(byteCount: PreviewLimits.streamingFileByteCount, format: .archive)
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: .max, format: .archive) }
        try PreviewLimits.validate(byteCount: 4 * 1024 * 1024 * 1024, format: .video)
    }

    @Test(arguments: [FileFormat.binary, .machO, .text, .audio, .video])
    func `Windowed readers and bounded text previews accept large files`(format: FileFormat) throws {
        try PreviewLimits.validate(byteCount: .max, format: format)
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: -1, format: format) }
    }

    @Test
    func `Text line objects are bounded and CRLF is one line break`() {
        let text = Data(String(repeating: "a\r\n", count: 100_000).utf8)
        #expect(PreviewLimits.textPrefixByteCount(text) == 299_998)
        #expect(PreviewLimits.textPrefixByteCount(Data("ordinary\ntext".utf8)) == 13)
        #expect(PreviewLimits.textByteCount == 32 * 1024 * 1024)
    }

    @Test
    func `Property-list depth and node budgets reject excessive editor trees`() throws {
        var tree: Any = "leaf"
        for _ in 0 ..< 64 {
            tree = [tree]
        }
        try PropertyListBudget.validate(tree)
        #expect(throws: FormatFailure.self) { try PropertyListBudget.validate([tree]) }
        #expect(throws: FormatFailure.self) { try PropertyListBudget.validate(Array(repeating: 0, count: 100_000)) }
    }

    @Test
    func `The data initializer enforces the property-list byte cap before parsing`() {
        let data = Data(count: Int(PreviewLimits.textByteCount) + 1)
        #expect(throws: FormatFailure.tooLarge(byteCount: Int64(data.count), limit: PreviewLimits.textByteCount)) {
            try PropertyListDocument(data: data)
        }
    }

    @Test
    func `A nested archive checks its output size before writing`() throws {
        try withScratch { directory in
            let archive = directory.appendingPathComponent("small.zip")
            try withDescriptor(writing: archive) { descriptor in
                let writer = try ArchiveWriter(descriptor: descriptor, format: .zip)
                try writer.addData("file", Data(repeating: 7, count: 17))
                try writer.finish()
            }
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                let member = try reader.next()
                _ = try #require(member)
                let output = directory.appendingPathComponent("output")
                try withDescriptor(writing: output) { destination in
                    #expect(throws: FormatFailure.self) { try reader.read(into: destination, maximumByteCount: 16) }
                }
                #expect(try Data(contentsOf: output).isEmpty)
            }
            try withDescriptor(reading: archive) { descriptor in
                let reader = try ArchiveReader(descriptor: descriptor)
                let member = try reader.next()
                _ = try #require(member)
                try withDescriptor(writing: directory.appendingPathComponent("accepted")) { destination in
                    let count = try reader.read(into: destination, maximumByteCount: 17)
                    #expect(count == 17)
                }
            }
        }
    }
}

struct ArchiveSpaceEstimateTests {
    private func entry(_ size: Int64?) -> ArchiveEntry {
        ArchiveEntry(declaredPath: "file", kind: .regular, byteCount: size, mode: S_IFREG | 0o644)
    }

    @Test
    func `Warn only above ninety percent, including zero available space`() {
        #expect(!ArchiveSpaceEstimate(entries: [entry(90)]).needsWarning(availableByteCount: 100))
        #expect(ArchiveSpaceEstimate(entries: [entry(91)]).needsWarning(availableByteCount: 100))
        #expect(ArchiveSpaceEstimate(entries: [entry(1)]).needsWarning(availableByteCount: 0))
        #expect(!ArchiveSpaceEstimate(entries: []).needsWarning(availableByteCount: 0))
    }

    /// The warning message reports this fraction instead of spelling a percent
    /// sign, so it has to be the same ratio `needsWarning` actually applies.
    @Test
    func `The published fraction is the threshold the warning uses`() {
        let available: Int64 = 1000
        let boundary = Int64(Double(available) * ArchiveSpaceEstimate.warningFraction)
        #expect(!ArchiveSpaceEstimate(entries: [entry(boundary)]).needsWarning(availableByteCount: available))
        #expect(ArchiveSpaceEstimate(entries: [entry(boundary + 1)]).needsWarning(availableByteCount: available))
    }

    @Test
    func `Unknown lengths do not imply low storage; known overflowing sizes still warn`() {
        let unknown = ArchiveSpaceEstimate(entries: [entry(nil)])
        #expect(unknown.hasUnknownSize)
        #expect(!unknown.needsWarning(availableByteCount: .max))
        #expect(ArchiveSpaceEstimate(entries: [entry(nil), entry(91)]).needsWarning(availableByteCount: 100))
        let sum = ArchiveSpaceEstimate(entries: [entry(.max), entry(1)])
        #expect(sum.byteCount == .max)
        #expect(sum.needsWarning(availableByteCount: .max))
    }
}
