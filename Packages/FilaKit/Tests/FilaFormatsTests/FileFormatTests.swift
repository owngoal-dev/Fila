@testable import FilaFormats
import Foundation
import Testing

@Suite("Format detection")
struct FileFormatTests {
    @Test
    func `Content wins over the name, because half these files have no extension`() {
        #expect(FileFormat.detect(head: Data("bplist00".utf8), name: "anything.txt") == .propertyList)
        #expect(FileFormat.detect(head: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]), name: "launchd") == .machO)
        #expect(FileFormat.detect(head: Data("%PDF-1.4".utf8), name: "notes") == .pdf)
    }

    @Test
    func `The name is the fallback when nothing is recognised`() {
        #expect(FileFormat.detect(head: Data(), name: "a.plist") == .propertyList)
        #expect(FileFormat.detect(head: Data(), name: "photo.HEIC") == .image)
    }

    @Test
    func `The name alone says nothing without a known extension`() {
        #expect(FileFormat.detect(name: "notes.txt") == .text)
        #expect(FileFormat.detect(name: "hosts") == nil)
        #expect(FileFormat.detect(name: "state.zqx") == nil)
    }

    @Test
    func `A NUL byte is what separates a binary from something worth editing`() {
        #expect(FileFormat.detect(head: Data("# Fila\nhello".utf8), name: "unnamed") == .text)
        #expect(FileFormat.detect(head: Data([0x68, 0x00, 0x69]), name: "unnamed") == .binary)
    }

    @Test(arguments: ["main.caml", "document.xml", "unnamed", "module.dylib"])
    func `CAML and generic XML are text, regardless of their XML declaration`(name: String) {
        let head = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\"><CALayer/>".utf8)
        #expect(FileFormat.detect(head: head, name: name) == .text)
        #expect(FileFormat.detect(head: Data("<?xml version=\"1.0\"?><document><!-- <plist> --></document>".utf8), name: name) == .text)
    }

    @Test
    func `An XML plist is identified by its root, including after a BOM and comments`() {
        let head = Data("\u{feff}<?xml version=\"1.0\"?>\n<!-- preferences -->\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>".utf8)
        #expect(FileFormat.detect(head: head, name: "settings") == .propertyList)
        #expect(FileFormat.detect(head: Data("<plist><dict/>".utf8), name: "settings.xml") == .propertyList)
    }

    @Test
    func `Text fallback accepts legacy bytes and a multibyte character cut by the detection window`() {
        let truncated = Data((String(repeating: "a", count: 511) + "你好").utf8.prefix(FileFormat.detectionByteCount))
        #expect(FileFormat.detect(head: truncated, name: "unknown") == .text)
        #expect(FileFormat.detect(head: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]), name: "unknown") == .text)
        #expect(FileFormat.detect(head: Data(), name: "unknown") == .text)
        #expect(FileFormat.detect(head: Data([0x01, 0x02, 0x03]), name: "unknown") == .binary)
    }

    @Test
    func `System types cover formats outside the extension table`() {
        #expect(FileFormat.detect(head: Data(), name: "picture.svg") == .image)
        #expect(FileFormat.detect(head: Data(), name: "picture.tif") == .image)
        #expect(FileFormat.detect(head: Data(), name: "document.rtf") == .text)
        #expect(FileFormat.detect(head: Data(), name: "animation.caml") == .text)
    }

    @Test
    func `Mach-O requires content evidence; static libraries are archives`() {
        #expect(FileFormat.detect(head: Data("ordinary text".utf8), name: "module.dylib") == .text)
        #expect(FileFormat.detect(head: Data("ordinary text".utf8), name: "module.so") == .text)
        #expect(FileFormat.detect(head: Data("!<arch>\n".utf8), name: "library.a") == .archive)
        #expect(FileFormat.detect(head: Data(), name: "library.a") == .archive)
        #expect(FileFormat.detect(head: Data([0xFE, 0xED, 0xFA, 0xCF]), name: "main.caml") == .machO)
    }
}
