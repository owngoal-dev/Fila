import Darwin
import Foundation
import Testing

@testable import FilaTerminal

@Suite("Terminal temporary configurations")
struct TerminalTemporaryFilesTests {
    @Test("Cleanup removes new configurations while preserving workspace and unrelated files")
    func configurations() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("wiki.qaq.fila")
        try TerminalTemporaryFiles.cleanup(in: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let workspace = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let sharedFile = workspace.appendingPathComponent("shared.txt")
        let unrelated = directory.appendingPathComponent("ghostty-config-not-a-uuid.conf")
        let oldLoose = root.appendingPathComponent(configName())
        for file in [sharedFile, unrelated, oldLoose] {
            try "keep".write(to: file, atomically: true, encoding: .utf8)
        }
        // A later pass models exit and the next launch after another config
        // was created. Cleanup has no once-only state that can miss that file.
        for _ in 0..<2 {
            let config = directory.appendingPathComponent(configName())
            try "font-size = 10".write(to: config, atomically: true, encoding: .utf8)
            try TerminalTemporaryFiles.cleanup(in: directory)
            #expect(!FileManager.default.fileExists(atPath: config.path))
        }
        for file in [sharedFile, unrelated, oldLoose] {
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }

    @Test("Cleanup unlinks a configuration symlink without changing its target")
    func configurationLink() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("wiki.qaq.fila")
        try TerminalTemporaryFiles.cleanup(in: directory)
        let target = root.appendingPathComponent("keep.txt")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(configName())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try TerminalTemporaryFiles.cleanup(in: directory)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test("Cleanup refuses a symlink or an untrusted directory", arguments: [true, false])
    func invalidParent(symlink: Bool) throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let config = target.appendingPathComponent(configName())
        try "keep".write(to: config, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("wiki.qaq.fila")
        if symlink {
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        }
        #expect(throws: (any Error).self) {
            try TerminalTemporaryFiles.cleanup(in: symlink ? directory : target)
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == "keep")
    }

    private func configName() -> String { "ghostty-config-\(UUID().uuidString).conf" }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fila-terminal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
