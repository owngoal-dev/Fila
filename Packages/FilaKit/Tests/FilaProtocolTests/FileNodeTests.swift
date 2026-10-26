import FilaProtocol
import Testing

// A share sheet carries an item's bytes, and getting them is `open(2)` then
// `read(2)`. Only a regular file answers that with content; every other kind
// is a path that opens and then refuses, which is the "Invalid argument" a
// folder used to answer with.

@Suite("Only an item with bytes can be shared")
struct FileNodeTests {
    @Test
    func `A regular file is shareable`() {
        #expect(node(.regular).isShareable)
    }

    @Test
    func `A link to a regular file is shareable`() {
        #expect(node(.symbolicLink, link: SymbolicLink(target: "/etc/hosts", resolvedKind: .regular)).isShareable)
    }

    @Test(arguments: [FileKind.directory, .fifo, .socket, .blockDevice, .characterDevice, .unknown])
    func `A node that is not a regular file is not shareable`(_ kind: FileKind) {
        #expect(!node(kind).isShareable)
    }

    @Test(arguments: [FileKind.directory, .fifo, .socket, .blockDevice, .characterDevice, .unknown])
    func `A link to anything but a regular file is not shareable`(_ kind: FileKind) {
        #expect(!node(.symbolicLink, link: SymbolicLink(target: "/somewhere", resolvedKind: kind)).isShareable)
    }

    @Test
    func `A dangling link is not shareable`() {
        #expect(!node(.symbolicLink, link: SymbolicLink(target: "/missing", resolvedKind: nil)).isShareable)
    }

    /// The two rules are separate: a folder is somewhere to go and nothing to
    /// hand over, and a regular file is the other way round.
    @Test
    func `Navigation and sharing never both hold`() {
        for kind in [FileKind.regular, .directory, .fifo, .socket, .blockDevice, .characterDevice, .unknown] {
            #expect(!(node(kind).isNavigable && node(kind).isShareable))
        }
        #expect(node(.directory).isNavigable)
        #expect(node(.symbolicLink, link: SymbolicLink(target: "/tmp", resolvedKind: .directory)).isNavigable)
    }

    private func node(_ kind: FileKind, link: SymbolicLink? = nil) -> FileNode {
        FileNode(
            name: "item",
            kind: kind,
            size: 0,
            allocatedSize: 0,
            modified: 0,
            created: 0,
            accessed: 0,
            mode: 0,
            ownerID: 501,
            groupID: 501,
            systemFlags: 0,
            linkCount: 1,
            inode: 42,
            link: link,
        )
    }
}
