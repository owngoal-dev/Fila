import Darwin
@testable import FilaProvider
import Foundation
import Testing

/// A root with a file, a folder, a nested file, a symlink and a hard link.
private func treeFixture(_ body: (ProviderTree, URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let root = base.appendingPathComponent("Documents")
    let index = base.appendingPathComponent("Group/.fila-provider/index.json")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
    try Data("two".utf8).write(to: root.appendingPathComponent("Folder/two.txt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)
    try Data("shared".utf8).write(to: root.appendingPathComponent("shared.txt"))
    try FileManager.default.linkItem(at: root.appendingPathComponent("shared.txt"), to: root.appendingPathComponent("shared-2.txt"))
    try body(ProviderTree(root: root, index: index), root, index)
}

@Test func treeListsRegularFilesAndFoldersOnly() throws {
    try treeFixture { tree, _, _ in
        let names = try tree.children(of: nil).map(\.name).sorted()
        #expect(names == ["Folder", "one.txt"])
        let folder = try #require(try tree.children(of: nil).first { $0.isDirectory })
        #expect(try tree.children(of: folder.id).map(\.name) == ["two.txt"])
        #expect(try tree.all().map(\.path).sorted() == ["Folder", "Folder/two.txt", "one.txt"])
    }
}

@Test func treeKeepsIdentityAcrossRenameAndMove() throws {
    try treeFixture { tree, root, _ in
        let children = try tree.children(of: nil)
        let file = try #require(children.first { $0.name == "one.txt" })
        let folder = try #require(children.first { $0.isDirectory })
        let renamed = try tree.move(file.id, name: "uno.txt", parent: folder.id)
        #expect(renamed.id == file.id)
        #expect(renamed.path == "Folder/uno.txt")
        #expect(renamed.metadataVersion != file.metadataVersion)
        #expect(renamed.contentVersion == file.contentVersion)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/uno.txt").path))
        // The folder's children moved with it.
        let movedFolder = try tree.move(folder.id, name: "Renamed", parent: nil)
        #expect(try tree.entry(file.id).path == "Renamed/uno.txt")
        #expect(try tree.children(of: movedFolder.id).map(\.name).sorted() == ["two.txt", "uno.txt"])
        // Into itself, and onto an existing name, are refused.
        #expect(throws: ProviderTree.Failure.invalidName) { try tree.move(movedFolder.id, name: "Inner", parent: movedFolder.id) }
        try Data("taken".utf8).write(to: root.appendingPathComponent("taken.txt"))
        #expect(throws: ProviderTree.Failure.collision) { try tree.move(file.id, name: "taken.txt", parent: nil) }
    }
}

@Test func treeReportsExternalChangesAgainstAnAnchor() throws {
    try treeFixture { tree, root, _ in
        _ = try tree.all()
        let anchor = tree.anchor
        try Data("changed".utf8).write(to: root.appendingPathComponent("one.txt"))
        try Data("new".utf8).write(to: root.appendingPathComponent("Folder/three.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/two.txt"))
        let changes = try #require(try tree.changes(since: anchor))
        #expect(changes.updated.map(\.path).sorted() == ["Folder", "Folder/three.txt", "one.txt"])
        #expect(changes.deleted.map(\.path) == ["Folder/two.txt"])
        #expect(changes.anchor != anchor)
        // Nothing since the new anchor; the old one is still answerable.
        let quiet = try #require(try tree.changes(since: changes.anchor))
        #expect(quiet.updated.isEmpty && quiet.deleted.isEmpty)
        #expect(try tree.changes(since: anchor)?.deleted.map(\.path) == ["Folder/two.txt"])
        #expect(try tree.changes(since: Data("nonsense".utf8)) == nil)
    }
}

@Test func treeMutationsAreExclusiveAndAtomic() throws {
    try treeFixture { tree, root, _ in
        let source = root.deletingLastPathComponent().appendingPathComponent("import.txt")
        try Data("imported".utf8).write(to: source)
        let created = try tree.createFile(name: "import.txt", parent: nil, contents: source)
        #expect(try String(contentsOf: root.appendingPathComponent("import.txt"), encoding: .utf8) == "imported")
        #expect(throws: ProviderTree.Failure.collision) { try tree.createFile(name: "import.txt", parent: nil, contents: source) }
        #expect(try tree.existing(name: "import.txt", parent: nil)?.id == created.id)
        let empty = try tree.createFile(name: "empty.bin", parent: nil, contents: nil)
        #expect(empty.size == 0)
        let folder = try tree.createDirectory(name: "New", parent: nil)
        #expect(folder.isDirectory)
        #expect(throws: ProviderTree.Failure.invalidName) { try tree.createDirectory(name: "a/b", parent: nil) }

        try Data("replaced".utf8).write(to: source)
        let replaced = try tree.replaceContents(of: created.id, with: source)
        #expect(replaced.id != created.id)
        #expect(replaced.path == created.path)
        #expect(try String(contentsOf: root.appendingPathComponent("import.txt"), encoding: .utf8) == "replaced")
        #expect(throws: ProviderTree.Failure.missing) { try tree.entry(created.id) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".fila-provider-") }.isEmpty)

        let stamped = try tree.setModificationDate(replaced.id, Date(timeIntervalSince1970: 1_000_000))
        #expect(Int(stamped.modified.timeIntervalSince1970) == 1_000_000)
        let beforeEpoch = try tree.setModificationDate(replaced.id, Date(timeIntervalSince1970: -0.5))
        #expect(beforeEpoch.modified.timeIntervalSince1970 == -0.5)

        let exported = root.deletingLastPathComponent().appendingPathComponent("export.txt")
        try tree.exportContents(of: replaced.id, to: exported)
        #expect(try String(contentsOf: exported, encoding: .utf8) == "replaced")
        #expect(throws: ProviderTree.Failure.collision) { try tree.exportContents(of: replaced.id, to: exported) }
        #expect(try String(contentsOf: exported, encoding: .utf8) == "replaced")
        #expect(try FileManager.default.contentsOfDirectory(atPath: exported.deletingLastPathComponent().path).filter { $0.hasPrefix(".fila-provider-") }.isEmpty)
        #expect(throws: ProviderTree.Failure.unsupported) { try tree.exportContents(of: folder.id, to: exported) }
    }
}

@Test func treeDeletesEmptyFoldersOnlyUnlessRecursive() throws {
    try treeFixture { tree, root, _ in
        let folder = try #require(try tree.children(of: nil).first { $0.isDirectory })
        #expect(throws: ProviderTree.Failure.directoryNotEmpty) { try tree.delete(folder.id, recursive: false) }
        try tree.delete(folder.id, recursive: true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        #expect(throws: ProviderTree.Failure.missing) { try tree.entry(folder.id) }
        let file = try #require(try tree.children(of: nil).first { $0.name == "one.txt" })
        try tree.delete(file.id, recursive: false)
        #expect(try tree.children(of: nil).isEmpty)
    }
}

@Test func treeIndexSurvivesReopenAndCorruption() throws {
    try treeFixture { tree, root, index in
        _ = try tree.all()
        let anchor = tree.anchor
        let file = try #require(try tree.children(of: nil).first { $0.name == "one.txt" })
        let reopened = try ProviderTree(root: root, index: index)
        #expect(reopened.anchor == anchor)
        #expect(try reopened.entry(file.id).path == "one.txt")
        try Data("garbage".utf8).write(to: index)
        let recovered = try ProviderTree(root: root, index: index)
        #expect(try recovered.changes(since: anchor) == nil)
        #expect(try recovered.entry(file.id).id == file.id)
    }
}

@Test func treeRetriesAnIndexWriteWithoutAdvancingItsAnchor() throws {
    try treeFixture { tree, root, index in
        _ = try tree.all()
        let original = tree.anchor
        try Data("new".utf8).write(to: root.appendingPathComponent("new.txt"))
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try tree.all() }
        #expect(tree.anchor == original)

        try FileManager.default.removeItem(at: index)
        #expect(try tree.all().contains { $0.name == "new.txt" })
        let reopened = try ProviderTree(root: root, index: index)
        #expect(reopened.anchor == tree.anchor)
        #expect(reopened.anchor != original)
    }
}

@Test func treeDoesNotReturnADeletedEntryDuringRescanThrottling() throws {
    try treeFixture { tree, root, _ in
        let file = try #require(try tree.all().first { $0.name == "one.txt" })
        try FileManager.default.removeItem(at: root.appendingPathComponent(file.path))
        #expect(throws: ProviderTree.Failure.missing) { try tree.entry(file.id) }
        #expect(throws: ProviderTree.Failure.missing) { try tree.entry(file.id) }
    }
}

@Test func treeCopiesImmutableInputAndUsesDestinationFlagsOnReplacement() throws {
    try treeFixture { tree, root, _ in
        let source = root.deletingLastPathComponent().appendingPathComponent("locked.txt")
        try Data("locked contents".utf8).write(to: source)
        try #require(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(source.path, 0) }
        let importedPath = root.appendingPathComponent("imported.txt")
        defer { _ = chflags(importedPath.path, 0) }
        _ = try tree.createFile(name: "imported.txt", parent: nil, contents: source)
        var imported = stat()
        try #require(lstat(importedPath.path, &imported) == 0)
        #expect(imported.st_flags & UInt32(UF_IMMUTABLE) != 0)

        let mutable = try tree.createFile(name: "mutable.txt", parent: nil, contents: nil)
        let replaced = try tree.replaceContents(of: mutable.id, with: source)
        #expect(try String(contentsOf: root.appendingPathComponent(replaced.path), encoding: .utf8) == "locked contents")
        var metadata = stat()
        try #require(lstat(root.appendingPathComponent(replaced.path).path, &metadata) == 0)
        #expect(metadata.st_flags & UInt32(UF_IMMUTABLE) == 0)
    }
}
