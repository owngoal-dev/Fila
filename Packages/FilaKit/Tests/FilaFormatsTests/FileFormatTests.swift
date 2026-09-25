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
        #expect(FileFormat.detect(head: Data(), name: "animation.caml") == .text)
    }

    private static let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
    private static let compoundFile = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0x00])

    @Test(arguments: ["report.docx", "deck.pptx", "sheet.XLSX", "notes.pages", "budget.numbers", "talk.key", "macro.xlsm"])
    func `A ZIP named as a document is that document, not an archive`(name: String) {
        #expect(FileFormat.detect(head: Self.zip, name: name) == .document)
        #expect(FileFormat.detect(name: name) == .document)
        #expect(FileFormat.documentMIMEType(name: name) != nil)
    }

    @Test(arguments: ["report.doc", "deck.ppt", "sheet.xls", "show.pps"])
    func `An OLE compound file named as a legacy Office document is that document`(name: String) {
        #expect(FileFormat.detect(head: Self.compoundFile, name: name) == .document)
    }

    @Test
    func `RTF is a document when its bytes say RTF`() {
        #expect(FileFormat.detect(head: Data("{\\rtf1\\ansi hello}".utf8), name: "letter.rtf") == .document)
        #expect(FileFormat.documentMIMEType(name: "letter.rtf") == "application/rtf")
    }

    @Test
    func `A document extension over the wrong bytes is detected as the bytes are`() {
        // A PEM private key and a plain-text README are the usual strangers.
        #expect(FileFormat.detect(head: Data("-----BEGIN PRIVATE KEY-----\n".utf8), name: "server.key") == .text)
        #expect(FileFormat.detect(head: Data("Read me first.\n".utf8), name: "README.doc") == .text)
        #expect(FileFormat.detect(head: Data("%PDF-1.7".utf8), name: "report.docx") == .pdf)
        #expect(FileFormat.detect(head: Self.zip, name: "report.doc") == .archive)
        #expect(FileFormat.detect(head: Data([0x01, 0x02, 0x03]), name: "deck.pptx") == .binary)
    }

    @Test
    func `With no bytes, the name decides, as it does for a list icon`() {
        #expect(FileFormat.detect(head: Data(), name: "report.docx") == .document)
        #expect(FileFormat.detect(head: Data(), name: "document.rtf") == .document)
    }

    @Test
    func `Without a name, a document's bytes are their container: archive, hex or text`() {
        #expect(FileFormat.detect(head: Self.zip, name: "") == .archive)
        #expect(FileFormat.detect(head: Self.compoundFile, name: "") == .binary)
        #expect(FileFormat.detect(head: Data("{\\rtf1 hello}".utf8), name: "") == .text)
    }

    @Test(arguments: ["archive.zip", "notes.txt", "spreadsheet.csv", "notes.odt", "unnamed"])
    func `Names outside the document table have no document MIME type`(name: String) {
        #expect(FileFormat.documentMIMEType(name: name) == nil)
        #expect(FileFormat.detect(name: name) != .document)
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
