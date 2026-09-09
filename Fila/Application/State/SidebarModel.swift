import FilaBackendKit
import Foundation

/// The combined sidebar: every registered backend's contribution, merged in
/// registry order and republished whenever one of them changes.
///
/// A projection, not a store. Contributions are cached only so the others
/// need not be asked again when one changes; the bookmarks themselves live
/// in their backends. Backends report as they are ready — a backend that
/// has nothing yet simply has no rows — and nothing here waits for all of
/// them. A backend added after bootstrap — a share the user just saved —
/// joins at the end of the order; a removed one leaves with its
/// contribution, and a snapshot its retired instance publishes late is
/// ignored.
@MainActor
final class SidebarModel {
    private(set) var contributions: [BackendID: BackendSidebar] = [:]
    private(set) var order: [BackendID]
    private var subscriptions: [BackendID: Task<Void, Never>] = [:]
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var registryTask: Task<Void, Never>?

    init(backends: [any Backend], registry: BackendRegistry? = nil) {
        order = backends.map(\.id)
        for backend in backends {
            subscribe(backend)
        }
        guard let registry else { return }
        registryTask = Task { [weak self] in
            for await change in registry.changes() {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case let .added(id):
                    guard let backend = registry.backend(id) else { continue }
                    add(backend)
                case let .removed(id):
                    remove(id)
                }
            }
        }
    }

    deinit {
        registryTask?.cancel()
        for task in subscriptions.values { task.cancel() }
    }

    /// A hint that the combined sidebar changed; the reader re-derives what
    /// it shows. Newest-only, so a burst of changes is one rebuild.
    func updates() -> AsyncStream<Void> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[token] = nil }
            }
        }
    }

    func contribution(of backend: BackendID) -> BackendSidebar {
        contributions[backend] ?? .empty
    }

    private func add(_ backend: any Backend) {
        guard subscriptions[backend.id] == nil else { return }
        order.append(backend.id)
        subscribe(backend)
        publish()
    }

    private func remove(_ id: BackendID) {
        subscriptions.removeValue(forKey: id)?.cancel()
        tokens[id] = nil
        contributions[id] = nil
        order.removeAll { $0 == id }
        publish()
    }

    private func subscribe(_ backend: any Backend) {
        let id = backend.id
        let token = UUID()
        tokens[id] = token
        subscriptions[id] = Task { [weak self] in
            for await snapshot in backend.sidebarUpdates() {
                guard let self, !Task.isCancelled else { return }
                // A snapshot from an instance retired meanwhile lands
                // nowhere, even if its identity has been reused since.
                guard tokens[id] == token else { return }
                contributions[id] = snapshot
                publish()
            }
        }
    }

    private var tokens: [BackendID: UUID] = [:]

    private func publish() {
        for continuation in listeners.values {
            continuation.yield(())
        }
    }
}
