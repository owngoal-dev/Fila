import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Paged directory listing")
struct DirectoryListingTests {
    let scratch = Scratch()

    @Test
    func `Every entry arrives exactly once across pages`() throws {
        let expected = Set((0 ..< 25).map { "entry-\($0)" })
        for name in expected {
            scratch.file(name)
        }

        let registry = ListingRegistry()
        var seen: [String] = []
        var cursor: UInt64 = 0
        repeat {
            let page = try registry.page(directory: scratch.root, cursor: cursor, limit: 7)
            seen.append(contentsOf: page.entries.map(\.name))
            cursor = page.cursor
        } while cursor != 0

        #expect(Set(seen) == expected)
        #expect(seen.count == expected.count)
    }

    @Test
    func `. and .. are never entries`() throws {
        scratch.file("only")
        let page = try ListingRegistry().page(directory: scratch.root, cursor: 0)
        #expect(page.entries.map(\.name) == ["only"])
        #expect(page.cursor == 0)
    }

    @Test
    func `A symlink reports its target and what is there`() throws {
        scratch.file("target")
        scratch.directory("folder")
        scratch.link("to-file", to: scratch.path("target"))
        scratch.link("to-folder", to: scratch.path("folder"))
        scratch.link("dangling", to: scratch.path("nothing-here"))

        let page = try ListingRegistry().page(directory: scratch.root, cursor: 0)
        let entries = Dictionary(uniqueKeysWithValues: page.entries.map { ($0.name, $0) })

        #expect(entries["to-file"]?.kind == .symbolicLink)
        #expect(entries["to-file"]?.link?.target == scratch.path("target"))
        #expect(entries["to-file"]?.link?.resolvedKind == .regular)

        #expect(entries["to-folder"]?.link?.resolvedKind == .directory)
        #expect(entries["to-folder"]?.isNavigable == true)

        #expect(entries["dangling"]?.link?.resolvedKind == nil)
        #expect(entries["dangling"]?.link?.isBroken == true)
        #expect(entries["dangling"]?.isNavigable == false)
    }

    @Test
    func `The handle stays open between pages and closes at the end`() throws {
        for index in 0 ..< 5 {
            scratch.file("f\(index)")
        }
        let registry = ListingRegistry()

        let first = try registry.page(directory: scratch.root, cursor: 0, limit: 2)
        #expect(first.cursor != 0)
        #expect(registry.count == 1)

        var cursor = first.cursor
        while cursor != 0 {
            cursor = try registry.page(directory: scratch.root, cursor: cursor, limit: 2).cursor
        }
        #expect(registry.count == 0)
    }

    @Test
    func `Cancelling one listing releases its handle and leaves another cursor usable`() throws {
        for index in 0 ..< 5 {
            scratch.file("f\(index)")
        }
        let registry = ListingRegistry()
        let cancelled = try registry.page(directory: scratch.root, cursor: 0, limit: 1)
        let foreground = try registry.page(directory: scratch.root, cursor: 0, limit: 1)
        registry.close(cursor: cancelled.cursor)
        registry.close(cursor: cancelled.cursor)
        registry.close(cursor: 0)
        #expect(registry.count == 1)
        let failure = #expect(throws: FilaFailure.self) {
            _ = try registry.page(directory: scratch.root, cursor: cancelled.cursor)
        }
        #expect(failure?.systemError == ESTALE)
        let remaining = try registry.page(directory: scratch.root, cursor: foreground.cursor)
        #expect(remaining.entries.count == 4)
        #expect(registry.count == 0)
    }

    @Test
    func `Only so many listings stay open per peer, oldest evicted`() throws {
        for index in 0 ... FilaProtocol.concurrentListingsPerPeer {
            scratch.directory("d\(index)")
            for entry in 0 ..< 4 {
                scratch.file("d\(index)/e\(entry)")
            }
        }
        let registry = ListingRegistry()
        for index in 0 ... FilaProtocol.concurrentListingsPerPeer {
            _ = try registry.page(directory: scratch.path("d\(index)"), cursor: 0, limit: 1)
        }
        #expect(registry.count <= FilaProtocol.concurrentListingsPerPeer)
    }

    @Test
    func `A cursor the daemon has forgotten is refused, not silently restarted`() throws {
        scratch.file("a")
        let registry = ListingRegistry()
        #expect(throws: FilaFailure.self) {
            _ = try registry.page(directory: scratch.root, cursor: 999)
        }
    }

    @Test
    func `Listing something that is not a directory fails with its errno`() throws {
        let file = scratch.file("plain")
        let failure = #expect(throws: FilaFailure.self) {
            _ = try ListingRegistry().page(directory: file, cursor: 0)
        }
        #expect(failure?.systemError == ENOTDIR)
    }
}
