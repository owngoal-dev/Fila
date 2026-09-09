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
    /// Every way the user can add a connection, in module order.
    public private(set) var connectionSetups: [BackendConnectionSetup] = []

    /// Retained so a module's registrations keep their owner alive.
    private var entries: [any BackendModule] = []
    private var providers: [ObjectIdentifier: (module: BackendModuleIdentity, value: Any)] = [:]
    private var factories: [BackendFactory] = []
    private var routes: [BackendID: ScreenRoute] = [:]
    private var listeners: [UUID: AsyncStream<BackendRegistryChange>.Continuation] = [:]
    /// Factories whose run is in progress, so a factory asking for a
    /// backend its own module is still producing gets nil, not recursion.
    private var running: Set<BackendModuleIdentity> = []
    private weak var resolvingHost: (any BackendHost)?

    public init() {}

    public func provider<Provider>(_ type: Provider.Type) -> Provider? {
        providers[ObjectIdentifier(type)]?.value as? Provider
    }

    public func backend(_ id: BackendID) -> (any Backend)? {
        backends.first { $0.id == id }
    }

    /// The screen a module registered for `location`, or nil when no module
    /// routes that backend or its route declines the location.
    public func screen(for location: BackendLocation) -> AnyObject? {
        routes[location.backend]?.make(location)
    }

    /// A backend a module produced after bootstrap — the share the user
    /// just saved — with the screen its locations open in. Refused when the
    /// identity is taken, so a saved profile can never shadow another
    /// backend's bookmarks.
    public func add(_ backend: any Backend, screen: @escaping @MainActor (BackendLocation) -> AnyObject?) throws {
        guard self.backend(backend.id) == nil, routes[backend.id] == nil else {
            throw BackendModuleError.registration("backend \(backend.id) is already registered")
        }
        backends.append(backend)
        routes[backend.id] = ScreenRoute(module: nil, make: screen)
        publish(.added(backend.id))
    }

    /// Retires the backend `id` and its route. Its object stays alive for
    /// whoever still holds it — a screen mid-listing — and gets no new
    /// callers from here.
    public func remove(_ id: BackendID) {
        guard let index = backends.firstIndex(where: { $0.id == id }) else { return }
        backends.remove(at: index)
        routes[id] = nil
        publish(.removed(id))
    }

    /// Additions and removals after bootstrap, for whoever merges the
    /// backends' contributions. The startup set is read from `backends`;
    /// this stream carries only what changed since.
    public func changes() -> AsyncStream<BackendRegistryChange> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            listeners[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[token] = nil }
            }
        }
    }

    private func publish(_ change: BackendRegistryChange) {
        for continuation in listeners.values {
            continuation.yield(change)
        }
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
        for (backend, _) in registration.routes {
            if let existing = routes[backend] {
                let owner = existing.module?.bundleIdentifier ?? "a backend added at runtime"
                throw BackendModuleError.duplicateRoute("\(backend) (already from \(owner))")
            }
        }
        modules.append(module)
        entries.append(entry)
        for (key, provider) in registration.providers {
            providers[key] = (module, provider.value)
        }
        for (backend, route) in registration.routes {
            routes[backend] = route
        }
        factories.append(contentsOf: registration.backendFactories)
        connectionSetups.append(contentsOf: registration.connectionSetups)
    }

    /// Run every committed factory against the completed provider set.
    /// Factories run in module order unless one asks the resolver for a
    /// backend another module has not produced yet, which runs that
    /// module's factories first; either way the order is deterministic and
    /// independent of which framework dyld mapped first.
    func resolveBackends(host: any BackendHost) {
        resolvingHost = host
        while let next = factories.first {
            run(next, host: host)
        }
        resolvingHost = nil
    }

    /// A backend by id, running pending factories until one produces it.
    func resolve(_ id: BackendID) -> (any Backend)? {
        if let found = backend(id) {
            return found
        }
        guard let host = resolvingHost else { return nil }
        while let next = factories.first(where: { !running.contains($0.module) }) {
            run(next, host: host)
            if let found = backend(id) {
                return found
            }
        }
        return nil
    }

    private func run(_ factory: BackendFactory, host: any BackendHost) {
        factories.removeAll { $0.id == factory.id }
        running.insert(factory.module)
        defer { running.remove(factory.module) }
        let produced: [any Backend]
        do {
            produced = try factory.make(BackendResolver(host: host, registry: self))
        } catch {
            host.warn("backend failed to bootstrap: \(factory.module): \(error)")
            return
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
}

/// What changed in the registry after bootstrap.
public enum BackendRegistryChange: Sendable, Equatable {
    case added(BackendID)
    case removed(BackendID)
}
