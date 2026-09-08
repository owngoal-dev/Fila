@testable import FilaFormats
import Foundation
import Testing

@Suite("Property lists")
struct PropertyListTests {
    private var mixed: PropertyListValue {
        .dictionary([
            "Label": .string("wiki.qaq.filad"),
            "KeepAlive": .boolean(true),
            "Nice": .integer(-5),
            "ThrottleInterval": .integer(10),
            "Ratio": .real(0.5),
            "Stamp": .date(Date(timeIntervalSince1970: 1_700_000_000)),
            "Blob": .data(Data([0xDE, 0xAD, 0xBE, 0xEF])),
            "ProgramArguments": .array([.string("/usr/libexec/filad"), .integer(1)]),
        ])
    }

    @Test("Binary and XML both survive a round trip with their types intact", arguments: [PropertyListDocument.Format.binary, .xml])
    func roundTrip(format: PropertyListDocument.Format) throws {
        let document = PropertyListDocument(root: mixed, format: format)
        let restored = try PropertyListDocument(data: document.serialized())
        #expect(restored.format == format)
        #expect(restored.root == mixed)
    }

    @Test("An integer does not come back as a real, which is what breaks a launchd job")
    func integersStayIntegers() throws {
        let restored = try PropertyListDocument(data: PropertyListDocument(root: mixed, format: .binary).serialized())
        #expect(restored.root[[.key("Nice")]] == .integer(-5))
        #expect(restored.root[[.key("Ratio")]] == .real(0.5))
        #expect(restored.root[[.key("KeepAlive")]] == .boolean(true))
    }

    @Test("Converting a binary plist to XML and back is the edit a jailbreak user wants")
    func convertsBetweenFormats() throws {
        let binary = try PropertyListDocument(root: mixed, format: .binary).serialized()
        var document = try PropertyListDocument(data: binary)
        #expect(document.format == .binary)

        document.format = .xml
        let xml = try document.serialized()
        #expect(String(decoding: xml.prefix(5), as: UTF8.self) == "<?xml")
        #expect(try PropertyListDocument(data: xml).root == mixed)
    }

    @Test("A path addresses a row, and assigning nil removes it")
    func editsThroughPaths() {
        var root = mixed
        root[[.key("Label")]] = .string("wiki.qaq.other")
        root[[.key("ProgramArguments"), .index(1)]] = .string("--verbose")
        root[[.key("ProgramArguments"), .index(2)]] = .string("--appended")
        root[[.key("Nice")]] = nil

        #expect(root[[.key("Label")]] == .string("wiki.qaq.other"))
        #expect(root[[.key("ProgramArguments")]] == .array([.string("/usr/libexec/filad"), .string("--verbose"), .string("--appended")]))
        #expect(root[[.key("Nice")]] == nil)
    }

    @Test("A path that leads nowhere reads nil and changes nothing")
    func stalePathsAreInert() {
        var root = mixed
        root[[.key("Nice"), .key("deeper")]] = .string("x")
        root[[.key("ProgramArguments"), .index(99)]] = .string("x")
        #expect(root == mixed)
        #expect(root[[.index(0)]] == nil)
    }

    @Test("A plist read from a descriptor is the same one")
    func readsFromADescriptor() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("job.plist")
            try PropertyListDocument(root: mixed, format: .binary).serialized().write(to: url)
            let document = try withDescriptor(reading: url) { try PropertyListDocument(descriptor: $0) }
            #expect(document.format == .binary)
            #expect(document.root == mixed)
        }
    }

    @Test("Anything that is not a property list fails as damaged, not as a crash")
    func rejectsRubbish() {
        #expect(throws: FormatFailure.self) { try PropertyListDocument(data: Data(repeating: 0xFF, count: 32)) }
    }
}
