@testable import FilaProvider
import Foundation
import Testing

private func locationFixture(_ body: (URL, URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let group = base.appendingPathComponent("Group")
    let first = base.appendingPathComponent("Documents")
    let second = base.appendingPathComponent("Other")
    for url in [group, first, second] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: base) }
    try body(group, first, second)
}

@Test func providerLocationRetainsPreviousBindings() throws {
    try locationFixture { group, first, second in
        let original = try ProviderLocation.initializeDefault(documentsURL: first, in: group)
        let selected = try ProviderLocation.bind(to: second, isDefault: false, in: group)
        #expect(selected.generation != original.generation)
        #expect(try ProviderLocation.load(in: group) == selected)
        let old = try #require(try ProviderLocation.load(generation: original.generation, in: group))
        #expect(try old.resolve(in: group).resolvingSymlinksInPath().path == first.path)
        #expect(try ProviderLocation.initializeDefault(documentsURL: first, in: group) == selected)
    }
}

@Test func providerLocationDefaultsKeepOnlyMatchingGeneration() throws {
    try locationFixture { group, first, second in
        let initial = try ProviderLocation.initializeDefault(documentsURL: first, in: group)
        let refreshed = try ProviderLocation.initializeDefault(documentsURL: first, in: group)
        #expect(refreshed.generation == initial.generation)
        let moved = try ProviderLocation.initializeDefault(documentsURL: second, in: group)
        #expect(moved.generation != initial.generation)
        #expect(try ProviderLocation.load(generation: initial.generation, in: group)?.displayPath == initial.displayPath)
    }
}

@Test func providerLocationRejectsRecursiveAndMissingFolders() throws {
    try locationFixture { group, first, _ in
        let valid = try ProviderLocation.bind(to: first, isDefault: false, in: group)
        for invalid in [group, group.appendingPathComponent(".fila-provider-locations"), group.deletingLastPathComponent(), first.appendingPathComponent("missing")] {
            #expect(throws: (any Error).self) {
                try ProviderLocation.bind(to: invalid, isDefault: false, in: group)
            }
            #expect(try ProviderLocation.load(in: group) == valid)
        }
    }
}

@Test func providerLocationRejectsConfigurationSymlink() throws {
    try locationFixture { group, first, second in
        try Data("sentinel".utf8).write(to: second.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: group.appendingPathComponent(".fila-provider-location.json"), withDestinationURL: second.appendingPathComponent("sentinel"))
        #expect(throws: (any Error).self) { try ProviderLocation.initializeDefault(documentsURL: first, in: group) }
        #expect(try String(contentsOf: second.appendingPathComponent("sentinel"), encoding: .utf8) == "sentinel")
    }
}
