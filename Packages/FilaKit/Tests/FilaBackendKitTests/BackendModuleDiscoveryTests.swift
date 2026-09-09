import FilaBackendKit
import Foundation
import Testing

// MARK: - Fixtures

@MainActor
private final class RecordingHost: BackendHost {
    var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
    func warn(_ message: String) { lines.append(message) }
    var failures: [String] { lines.filter { $0.hasPrefix("backend failed to bootstrap") } }
    var bootstrapped: [String] { lines.filter { $0.hasPrefix("backend module bootstrapped") } }
}

private protocol Greeting { var text: String { get } }
private struct Hello: Greeting { let text = "hello" }

@MainActor
private final class Fixture: Backend {
    let id: BackendID
    let root: BackendRoot
    init(_ raw: String) {
        id = BackendID(raw)
        root = BackendRoot(location: .root(of: id), kind: .filesystem, displayName: raw, symbolName: "folder")
    }
}

@objc(FilaFixtureModule)
private final class FilaFixtureModule: NSObject, BackendModule {
    nonisolated(unsafe) static var onRegister: (@MainActor (BackendRegistration) throws -> Void)?
    required override init() {}
    func register(with registration: BackendRegistration) throws {
        try Self.onRegister?(registration)
    }
}

@objc(FilaPlainModule)
private final class FilaPlainModule: NSObject {
    required override init() {}
}

private let hostVersion = BackendHostVersion(shortVersion: "1.2.3", buildVersion: "45")

private func manifest(schema: Int = 1, contract: Int = 1, name: String = "Fixture") -> [String: Any] {
    [
        BackendModuleManifest.schemaKey: schema,
        BackendModuleManifest.contractKey: contract,
        BackendModuleManifest.displayNameKey: name,
    ]
}

private func candidate(
    _ identifier: String = "wiki.qaq.fila.fixture",
    framework: String = "FilaFixture",
    version: BackendHostVersion = hostVersion,
    manifest plist: [String: Any]? = manifest(),
    owns: @escaping (AnyClass) -> Bool = { _ in true }
) -> BackendModuleCandidate {
    BackendModuleCandidate(
        bundleIdentifier: identifier,
        frameworkName: framework,
        shortVersion: version.shortVersion,
        buildVersion: version.buildVersion,
        manifest: plist,
        entryClass: { NSClassFromString($0) },
        owns: owns
    )
}

// MARK: - Tests

@Suite("Backend module discovery", .serialized)
@MainActor
struct BackendModuleDiscoveryTests {
    init() { FilaFixtureModule.onRegister = nil }

    @Test("A module whose manifest, version and entry class check out is registered")
    func happyPath() {
        FilaFixtureModule.onRegister = { registration in
            try registration.provide(Greeting.self, Hello())
            registration.backends { resolver in
                #expect(resolver.provider(Greeting.self)?.text == "hello")
                return [Fixture("local")]
            }
        }
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap([candidate()], hostVersion: hostVersion, host: host)
        #expect(registry.modules.map(\.bundleIdentifier) == ["wiki.qaq.fila.fixture"])
        #expect(registry.modules.first?.entryClassName == "FilaFixtureModule")
        #expect(registry.backends.map(\.id) == [BackendID("local")])
        #expect(registry.provider(Greeting.self)?.text == "hello")
        #expect(host.failures.isEmpty)
        #expect(host.bootstrapped.count == 1)
    }

    @Test("A framework without a manifest is not a module and is ignored without a log line")
    func noManifest() {
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap(
            [candidate(manifest: nil)], hostVersion: hostVersion, host: host
        )
        #expect(registry.modules.isEmpty)
        #expect(host.lines.isEmpty)
    }

    @Test("A malformed manifest is refused before the entry class is touched")
    func badManifest() {
        var touched = false
        FilaFixtureModule.onRegister = { _ in touched = true }
        let host = RecordingHost()
        for plist in [[String: Any](), [BackendModuleManifest.schemaKey: "1"], manifest(name: "")] {
            _ = BackendModuleDiscovery.bootstrap([candidate(manifest: plist)], hostVersion: hostVersion, host: host)
        }
        #expect(host.failures.count == 3)
        #expect(host.failures.allSatisfy { $0.contains("manifest:") })
        #expect(!touched)
    }

    @Test("Schema and contract mismatches name both numbers")
    func contractMismatch() {
        let host = RecordingHost()
        _ = BackendModuleDiscovery.bootstrap([candidate(manifest: manifest(schema: 2))], hostVersion: hostVersion, host: host)
        _ = BackendModuleDiscovery.bootstrap([candidate(manifest: manifest(contract: 9))], hostVersion: hostVersion, host: host)
        #expect(host.failures[0].contains("manifest schema 2, host reads 1"))
        #expect(host.failures[1].contains("contract 9, host is 1"))
    }

    @Test("A module built from another version than the host is refused")
    func versionMismatch() {
        let host = RecordingHost()
        let stale = BackendHostVersion(shortVersion: "1.2.3", buildVersion: "44")
        let registry = BackendModuleDiscovery.bootstrap(
            [candidate(version: stale)], hostVersion: hostVersion, host: host
        )
        #expect(registry.modules.isEmpty)
        #expect(host.failures.first?.contains("module version 1.2.3 (44) differs from host 1.2.3 (45)") == true)
    }

    @Test("A missing, foreign or non-conforming entry class is refused")
    func entryClass() {
        let host = RecordingHost()
        _ = BackendModuleDiscovery.bootstrap([candidate(framework: "FilaMissing")], hostVersion: hostVersion, host: host)
        _ = BackendModuleDiscovery.bootstrap([candidate(owns: { _ in false })], hostVersion: hostVersion, host: host)
        _ = BackendModuleDiscovery.bootstrap([candidate(framework: "FilaPlain")], hostVersion: hostVersion, host: host)
        #expect(host.failures[0].contains("entry class FilaMissingModule not found"))
        #expect(host.failures[1].contains("belongs to another bundle"))
        #expect(host.failures[2].contains("does not conform to BackendModule"))
    }

    @Test("A module that throws during registration leaves nothing behind")
    func registrationFailure() {
        struct Boom: Error {}
        FilaFixtureModule.onRegister = { registration in
            try registration.provide(Greeting.self, Hello())
            registration.backends { _ in [Fixture("local")] }
            throw Boom()
        }
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap([candidate()], hostVersion: hostVersion, host: host)
        #expect(registry.modules.isEmpty)
        #expect(registry.backends.isEmpty)
        #expect(registry.provider(Greeting.self) == nil)
        #expect(host.failures.first?.contains("registration failed") == true)
    }

    @Test("Two modules cannot both supply one provider; the second is refused whole")
    func duplicateProvider() {
        FilaFixtureModule.onRegister = { registration in
            try registration.provide(Greeting.self, Hello())
            registration.backends { _ in [Fixture(registration.module.bundleIdentifier)] }
        }
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap(
            [candidate("wiki.qaq.fila.b"), candidate("wiki.qaq.fila.a")],
            hostVersion: hostVersion,
            host: host
        )
        #expect(registry.modules.map(\.bundleIdentifier) == ["wiki.qaq.fila.a"])
        #expect(registry.backends.map(\.id.rawValue) == ["wiki.qaq.fila.a"])
        #expect(host.failures.first?.contains("wiki.qaq.fila.b: provider Greeting") == true)
        #expect(host.failures.first?.contains("already from wiki.qaq.fila.a") == true)
    }

    @Test("The same module identity twice is refused the second time")
    func duplicateModule() {
        FilaFixtureModule.onRegister = { registration in
            registration.backends { _ in [Fixture("x")] }
        }
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap(
            [candidate(), candidate()], hostVersion: hostVersion, host: host
        )
        #expect(registry.modules.count == 1)
        #expect(registry.backends.count == 1)
        #expect(host.failures.first?.contains("module wiki.qaq.fila.fixture already registered") == true)
    }

    @Test("Backend factories run after every module registered, in module order, and a duplicate backend ID is dropped")
    func factoriesResolveLast() {
        var order: [String] = []
        FilaFixtureModule.onRegister = { registration in
            let name = registration.module.bundleIdentifier
            if name.hasSuffix("provider") {
                try registration.provide(Greeting.self, Hello())
            }
            registration.backends { resolver in
                order.append(name)
                guard resolver.provider(Greeting.self) != nil else { return [] }
                return [Fixture("shared")]
            }
        }
        let host = RecordingHost()
        let registry = BackendModuleDiscovery.bootstrap(
            [candidate("wiki.qaq.fila.a.consumer"), candidate("wiki.qaq.fila.z.provider")],
            hostVersion: hostVersion,
            host: host
        )
        // The consumer registered first yet still saw the provider from the
        // module registered after it.
        #expect(order == ["wiki.qaq.fila.a.consumer", "wiki.qaq.fila.z.provider"])
        #expect(registry.backends.count == 1)
        #expect(host.failures.count == 1)
        #expect(host.failures[0].contains("backend shared duplicates"))
    }

    @Test("Embedded candidate enumeration on the host finds no modules and does not crash")
    func embeddedOnHost() {
        #expect(BackendModuleDiscovery.embeddedCandidates(in: .main).isEmpty)
    }
}
