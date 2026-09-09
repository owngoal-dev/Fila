import FilaBackendKit
import Foundation

/// The combined sidebar: every registered backend's contribution, merged in
/// registry order and republished whenever one of them changes.
///
/// A projection, not a store. Contributions are cached only so the others
/// need not be asked again when one changes; the bookmarks themselves live
/// in their backends. Backends report as they are ready — a backend that
/// has nothing yet simply has no rows — and nothing here waits for all of
/// them.
@MainActor
final class SidebarModel {
    private(set) var contributions: [BackendID: BackendSidebar] = [:]
    let order: [BackendID]
    private var subscriptions: [BackendID: Task<Void, Never>] = [:]
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(backends: [any Backend]) {
        order = backends.map(\.id)
        for backend in backends {
            let id = backend.id
            subscriptions[id] = Task { [weak self] in
                for await snapshot in backend.sidebarUpdates() {
                    guard let self, !Task.isCancelled else { return }
                    contributions[id] = snapshot
                    publish()
                }
            }
        }
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

    private func publish() {
        for continuation in listeners.values {
            continuation.yield(())
        }
    }
}
