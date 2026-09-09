import FilaBackendKit
import Foundation
import Testing

@Suite("Service paths")
struct ServicePathTests {
    @Test("Splits, trims separators and composes lexically")
    func composition() throws {
        let path = try ServicePath("/Library/Preferences/")
        #expect(path.components == ["Library", "Preferences"])
        #expect(path.description == "Library/Preferences")
        #expect(path.name == "Preferences")
        #expect(path.parent?.components == ["Library"])
        #expect(try path.appending("a.plist").components == ["Library", "Preferences", "a.plist"])
        #expect(ServicePath.root.isRoot)
        #expect(ServicePath.root.parent == nil)
        #expect(try ServicePath("").isRoot)
    }

    @Test("Refuses every component that could climb out of a root")
    func validation() {
        #expect(throws: ServicePathError.relativeComponent("..")) { try ServicePath("a/../b") }
        #expect(throws: ServicePathError.relativeComponent(".")) { try ServicePath(components: ["."]) }
        #expect(throws: ServicePathError.emptyComponent) { try ServicePath("a//b") }
        #expect(throws: ServicePathError.separatorInComponent("a/b")) { try ServicePath(components: ["a/b"]) }
        #expect(throws: ServicePathError.nulInComponent) { try ServicePath.root.appending("a\0b") }
    }

    @Test("Round-trips through Codable as the joined string")
    func codable() throws {
        let original = try ServicePath("var/mobile/Documents")
        let data = try JSONEncoder().encode(original)
        #expect(String(data: data, encoding: .utf8) == "\"var\\/mobile\\/Documents\"")
        #expect(try JSONDecoder().decode(ServicePath.self, from: data) == original)
        let location = FileLocation(backend: BackendID("local"), path: original)
        let again = try JSONDecoder().decode(FileLocation.self, from: try JSONEncoder().encode(location))
        #expect(again == location)
    }

    @Test("A complete listing yields its entries once and then ends")
    func completeListing() async throws {
        let entry = FileEntry(name: "a", kind: .file, size: 1, modified: nil, isHidden: false)
        let listing = FileListing(entries: [entry])
        var batches: [[FileEntry]] = []
        for try await batch in listing { batches.append(batch) }
        #expect(batches == [[entry]])
        #expect(entry.entersDirectory == false)
        #expect(FileEntry(name: "d", kind: .symbolicLink(resolved: .directory), size: nil, modified: nil, isHidden: false).entersDirectory)
    }
}
