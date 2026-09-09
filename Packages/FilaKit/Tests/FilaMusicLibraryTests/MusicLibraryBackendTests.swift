import FilaBackendKit
@testable import FilaMusicLibrary
import Foundation
import Testing

@Suite("Music library backend")
@MainActor
struct MusicLibraryBackendTests {
    @Test("The root row is offered only where a library exists")
    func gating() {
        #expect(MusicLibraryBackend(libraryExists: { false }).sidebar().places.isEmpty)
        let backend = MusicLibraryBackend(libraryExists: { true })
        #expect(backend.sidebar().places.map(\.kind) == [.root])
        #expect(backend.sidebar().places.first?.location == .root(of: .musicLibrary))
        #expect(backend.root.kind == .catalog)
    }

    @Test("Export names are safe path components with the source extension")
    func exportNames() {
        #expect(MusicExportNaming.name(title: "A/B: C", sourcePath: "/x/y.m4a", untitled: "Untitled") == "A B  C.m4a")
        #expect(MusicExportNaming.name(title: "..", sourcePath: "/x/y", untitled: "Untitled") == "Untitled")
        #expect(MusicExportNaming.name(title: "", sourcePath: "/x/y.mp3", untitled: "Untitled") == "Untitled.mp3")
        let long = MusicExportNaming.name(title: String(repeating: "x", count: 300), sourcePath: "/y.mp3", untitled: "U")
        #expect(long.utf8.count <= 184)
    }

    @Test("Change hints arrive at once and on every library change")
    func changes() async {
        let backend = MusicLibraryBackend(libraryExists: { true })
        var iterator = backend.changes().makeAsyncIterator()
        #expect(await iterator.next() != nil)
        backend.libraryChanged()
        #expect(await iterator.next() != nil)
    }
}
