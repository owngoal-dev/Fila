import Darwin
import FilaFileOps
import FilaFormats
import FilaProtocol
import Foundation
import Testing

@testable import FilaClient

@Suite("App installation fixture")
struct AppInstallFixtureTests {
    private func link() async throws -> DaemonLink {
        let link = DaemonLink(daemonIsInstalled: false, grace: 0)
        _ = try? await link.hello()
        _ = try await link.hello()
        return link
    }

    @Test("A RootHide fixture copies, archives and cleans up without importing runtime additions", arguments: [false, true])
    func runtimeAdditions(dangling: Bool) async throws {
        let scratch = LocalScratch()
        let bootstrap = scratch.directory("bootstrap")
        let bundle = scratch.directory("bootstrap/Applications/Fila.app")
        let workspace = scratch.directory("bootstrap/.fila-tmp/workspace")
        let payload = scratch.directory("bootstrap/.fila-tmp/workspace/Payload")
        let destination = payload + "/Fixture.app"
        let operations = FileOperations(bootstrapRoot: bootstrap)
        scratch.file("bootstrap/keep", contents: "bootstrap sentinel")
        scratch.file("bootstrap/Applications/Fila.app/Fila", contents: "executable")
        scratch.file("bootstrap/Applications/Fila.app/Info.plist", contents: "original identity")
        scratch.directory("bootstrap/Applications/Fila.app/Frameworks/Example.framework")
        scratch.file("bootstrap/Applications/Fila.app/Frameworks/Example.framework/Example", contents: "framework")
        scratch.directory("bootstrap/Applications/Fila.app/PlugIns/Provider.appex")
        scratch.file("bootstrap/Applications/Fila.app/PlugIns/Provider.appex/Info.plist", contents: "real extension identity")
        try operations.setAttributes(AttributeChange(mode: 0o755), at: bundle + "/Fila")
        try operations.create(.symbolicLink(target: dangling ? scratch.path("missing") : bootstrap), at: bundle + "/.jbroot")
        try operations.create(.symbolicLink(target: "Fila"), at: bundle + "/internal-link")

        // The original failure remains a guard refusal. Fixing the fixture
        // must not make a link to the live bootstrap deletable.
        if !dangling {
            #expect(throws: FilaFailure(code: .protectedPath, path: bundle + "/.jbroot")) {
                try operations.resolveForDestruction(bundle + "/.jbroot")
            }
        }

        try operations.create(.directory, at: destination)
        let request = try await AppInstallFixture.copyRequest(
            from: URL(fileURLWithPath: bundle), to: URL(fileURLWithPath: destination), link: link()
        )
        let copy = FileJob(request: request, operations: operations).run(report: { _ in })
        try #require(copy.code == .success)
        #expect(!exists(destination + "/.jbroot"))
        #expect(!exists(destination + "/PlugIns"))
        #expect(try String(contentsOfFile: destination + "/Frameworks/Example.framework/Example", encoding: .utf8) == "framework")
        #expect(try operations.details(of: destination + "/Fila").node.mode & 0o777 == 0o755)
        #expect(try operations.details(of: destination + "/internal-link").node.kind == .symbolicLink)

        let ipa = workspace + "/Fixture.ipa"
        let archive = ArchiveJob(
            request: JobRequest(kind: .compress, sources: [payload], destination: ipa, archive: ArchiveOptions()),
            operations: operations
        ).run(report: { _ in })
        try #require(archive.code == .success)
        let descriptor = try operations.open(ipa, flags: O_RDONLY, mode: 0)
        let entries: [ArchiveEntry]
        do {
            defer { close(descriptor) }
            entries = try ArchiveReader.list(descriptor: descriptor)
        }
        #expect(entries.contains { $0.declaredPath == "Payload/Fixture.app/Fila" })
        #expect(entries.contains { $0.declaredPath == "Payload/Fixture.app/Frameworks/Example.framework/Example" })
        #expect(!entries.contains { $0.declaredPath.split(separator: "/").contains(".jbroot") })
        #expect(!entries.contains { $0.declaredPath.split(separator: "/").contains("PlugIns") })

        let cleanup = FileJob(request: JobRequest(kind: .delete, sources: [workspace]), operations: operations).run(report: { _ in })
        try #require(cleanup.code == .success)
        #expect(!exists(workspace))
        #expect(exists(bundle + "/.jbroot"))
        #expect(try String(contentsOfFile: bundle + "/Info.plist", encoding: .utf8) == "original identity")
        #expect(try String(contentsOfFile: bundle + "/PlugIns/Provider.appex/Info.plist", encoding: .utf8) == "real extension identity")
        #expect(try String(contentsOfFile: bootstrap + "/keep", encoding: .utf8) == "bootstrap sentinel")
    }

    @Test("A bundle without runtime additions includes every listing page")
    func paginatedBundle() async throws {
        let scratch = LocalScratch()
        let bundle = scratch.directory("Fila.app")
        let destination = scratch.directory("Fixture.app")
        let count = FilaProtocol.directoryPageEntryCount + 1
        for index in 0 ..< count { scratch.file("Fila.app/resource-\(index)") }
        let request = try await AppInstallFixture.copyRequest(
            from: URL(fileURLWithPath: bundle), to: URL(fileURLWithPath: destination), link: link()
        )
        #expect(request.sources.count == count)
        let outcome = FileJob(request: request, operations: FileOperations(bootstrapRoot: "")).run(report: { _ in })
        try #require(outcome.code == .success)
        for index in 0 ..< count { #expect(exists(destination + "/resource-\(index)")) }
    }
}
