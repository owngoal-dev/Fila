import Foundation
import Testing

@testable import FilaFormats

@Suite("Format detection")
struct FileFormatTests {
    @Test("Content wins over the name, because half these files have no extension")
    func contentBeatsExtension() {
        #expect(FileFormat.detect(head: Data("bplist00".utf8), name: "anything.txt") == .propertyList)
        #expect(FileFormat.detect(head: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]), name: "launchd") == .machO)
        #expect(FileFormat.detect(head: Data("%PDF-1.4".utf8), name: "notes") == .pdf)
    }

    @Test("The name is the fallback when nothing is recognised")
    func extensionFallback() {
        #expect(FileFormat.detect(head: Data(), name: "a.plist") == .propertyList)
        #expect(FileFormat.detect(head: Data(), name: "photo.HEIC") == .image)
    }

    @Test("A NUL byte is what separates a binary from something worth editing")
    func binaryVersusText() {
        #expect(FileFormat.detect(head: Data("# Fila\nhello".utf8), name: "unnamed") == .text)
        #expect(FileFormat.detect(head: Data([0x68, 0x00, 0x69]), name: "unnamed") == .binary)
    }
}
