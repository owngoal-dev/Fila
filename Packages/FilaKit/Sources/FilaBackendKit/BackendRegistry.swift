import Foundation

/// Everything the bootstrapped modules registered, in module order.
///
/// Owned by the app for the life of the process. Modules are never
/// unloaded and a backend is never removed because a screen closed; a
/// backend that fails at runtime reports that failure through its own
/// operations, not by disappearing from here.
@MainActor
public final class BackendRegistry {
    public private(set) var modules: [BackendModuleIdentity] = []
    public private(set) var backends: [any Backend] = []

    /// Retained so a module's registrations keep their owner alive.
    private var entries: [any BackendModule] = []
    private var providers: [ObjectIdentifier: (module: BackendModuleIdentity, value: Any)] = [:]
    private var factories: [BackendFactory] = []

    public init() {}

    public func provider<Provider>(_ type: Provider.Type) -> Provider? {
        providers[ObjectIdentifier(type)]?.value as? Provider
    }

    public func backend(_ id: BackendID) -> (any Backend)? {
        backends.first { $0.id == id }
    }

    /// Apply one module's registrations, or none of them.
    func commit(_ registration: BackendRegistration, entry: any BackendModule) throws {
        let module = registration.module
        guard !modules.contains(module) else {
            throw BackendModuleError.duplicateModule(module.bundleIdentifier)
        }
        for (key, provider) in registration.providers {
            if let existing = providers[key] {
                throw BackendModuleError.duplicateProvider(
                    "\(provider.name) (already from \(existing.module.bundleIdentifier))"
                )
            }
        }
        modules.append(module)
        entries.append(entry)
        for (key, provider) in registration.providers {
            providers[key] = (module, provider.value)
        }
        factories.append(contentsOf: registration.backendFactories)
    }

    /// Run every committed factory against the completed provider set.
    /// Factories run in module order, so the resulting backend order is
    /// deterministic and independent of which framework dyld mapped first.
    func resolveBackends(host: any BackendHost) {
        let resolver = BackendResolver(host: host, registry: self)
        for factory in factories {
            let produced: [any Backend]
            do {
                produced = try factory.make(resolver)
            } catch {
                host.warn("backend failed to bootstrap: \(factory.module): \(error)")
                continue
            }
            for backend in produced {
                if let existing = backends.first(where: { $0.id == backend.id }) {
                    host.warn(
                        "backend failed to bootstrap: \(factory.module): backend \(backend.id) duplicates one already registered as \(type(of: existing))"
                    )
                    continue
                }
                backends.append(backend)
            }
        }
        factories.removeAll()
    }
}
