import Foundation
import Testing
import FilaProtocol
@testable import FilaFormats

struct PreviewLimitsTests {
    @Test("Memory-backed previews accept the byte ceiling and reject one byte over", arguments: [FileFormat.sqlite, .image, .pdf])
    func fileLimit(format: FileFormat) throws {
        try PreviewLimits.validate(byteCount: PreviewLimits.fileByteCount, format: format)
        #expect(throws: FormatFailure.self) {
            try PreviewLimits.validate(byteCount: PreviewLimits.fileByteCount + 1, format: format)
        }
    }

    @Test("Large archive browsing is bounded while media playback remains windowed")
    func streamingLimit() throws {
        try PreviewLimits.validate(byteCount: PreviewLimits.streamingFileByteCount, format: .archive)
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: .max, format: .archive) }
        try PreviewLimits.validate(byteCount: 4 * 1_024 * 1_024 * 1_024, format: .video)
    }

    @Test("Windowed readers and bounded text previews accept large files", arguments: [FileFormat.binary, .machO, .text, .audio, .video])
    func windowedReaders(format: FileFormat) throws {
        try PreviewLimits.validate(byteCount: .max, format: format)
        #expect(throws: FormatFailure.self) { try PreviewLimits.validate(byteCount: -1, format: format) }
    }

    @Test("Text line objects are bounded and CRLF is one line break")
    func textLines() {
        let text = Data(String(repeating: "a\r\n", count: 100_000).utf8)
        #expect(PreviewLimits.textPrefixByteCount(text) == 299_998)
        #expect(PreviewLimits.textPrefixByteCount(Data("ordinary\ntext".utf8)) == 13)
        #expect(PreviewLimits.textByteCount == 32 * 1_024 * 1_024)
    }

    @Test("Property-list depth and node budgets reject excessive editor trees")
    func propertyListTree() throws {
        var tree: Any = "leaf"
        for _ in 0..<64 { tree = [tree] }
        try PropertyListBudget.validate(tree)
        #expect(throws: FormatFailure.self) { try PropertyListBudget.validate([tree]) }
        #expect(throws: FormatFailure.self) { try PropertyListBudget.validate(Array(repeating: 0, count: 100_000)) }
    }

    @Test("The data initializer enforces the property-list byte cap before parsing")
    func propertyListBytes() {
        let data = Data(count: Int(PreviewLimits.textByteCount) + 1)
        #expect(throws: FormatFailure.tooLarge(byteCount: Int64(data.count), limit: PreviewLimits.textByteCount)) {
            try PropertyListDocument(data: data)
        }
    }

    @Test("A nested archive checks its output size before writing")
    func stagedMemberLimit() throws {
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

    @Test("Warn only above ninety percent, including zero available space")
    func threshold() {
        #expect(!ArchiveSpaceEstimate(entries: [entry(90)]).needsWarning(availableByteCount: 100))
        #expect(ArchiveSpaceEstimate(entries: [entry(91)]).needsWarning(availableByteCount: 100))
        #expect(ArchiveSpaceEstimate(entries: [entry(1)]).needsWarning(availableByteCount: 0))
        #expect(!ArchiveSpaceEstimate(entries: []).needsWarning(availableByteCount: 0))
    }

    @Test("Unknown lengths do not imply low storage; known overflowing sizes still warn")
    func unknownAndOverflow() {
        let unknown = ArchiveSpaceEstimate(entries: [entry(nil)])
        #expect(unknown.hasUnknownSize)
        #expect(!unknown.needsWarning(availableByteCount: .max))
        #expect(ArchiveSpaceEstimate(entries: [entry(nil), entry(91)]).needsWarning(availableByteCount: 100))
        let sum = ArchiveSpaceEstimate(entries: [entry(.max), entry(1)])
        #expect(sum.byteCount == .max)
        #expect(sum.needsWarning(availableByteCount: .max))
    }
}
