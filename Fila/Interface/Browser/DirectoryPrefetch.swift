import FilaProtocol
import UIKit

/// Disposable presentation data. Every destination still lists again after appearing.
/// One worker drains each listing so speculative reads do not fill the daemon's
/// cursor registry and evict the listing the user is actually waiting for.
@MainActor
final class DirectoryPrefetch {
    static let shared = DirectoryPrefetch()

    private final class Listing {
        let entries: [FileNode]?
        let date = Date()

        init(_ entries: [FileNode]?) { self.entries = entries }
    }

    private let cache = NSCache<NSString, Listing>()
    private var pending: [String] = []
    private var activePath: String?
    private var worker: Task<Void, Never>?

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = DirectoryReader.maximumEntryCount
        for name in [Notification.Name.filaJobFinished, UIApplication.didReceiveMemoryWarningNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: nil)
        }
    }

    func entries(in path: String) -> [FileNode]? {
        // An older snapshot is still useful during the push. The destination
        // refreshes after appearing, even if the user paused before tapping.
        cache.object(forKey: path as NSString)?.entries
    }

    func store(_ entries: [FileNode], in path: String) {
        cache.setObject(Listing(entries), forKey: path as NSString, cost: max(1, entries.count))
    }

    func prefetch(_ paths: [String]) {
        guard FileSession.shared.hello != nil, UIApplication.shared.applicationState != .background else { return }
        for path in paths where freshListing(in: path) == nil && activePath != path && !pending.contains(path) {
            pending.append(path)
        }
        // Scrolling quickly must not leave minutes of offscreen work queued.
        if pending.count > 128 { pending.removeFirst(pending.count - 128) }
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                let path = pending.removeFirst()
                guard freshListing(in: path) == nil else { continue }
                activePath = path
                let entries = try? await DirectoryReader.entries(in: path, session: .shared)
                guard !Task.isCancelled else { return }
                // A foreground refresh that finished meanwhile owns the newer result.
                if freshListing(in: path) == nil {
                    cache.setObject(Listing(entries), forKey: path as NSString, cost: max(1, entries?.count ?? 0))
                }
                activePath = nil
            }
            worker = nil
        }
    }

    func prefetchSidebar() {
        let places = SidebarLocation.orderedDestinations.compactMap { destination -> String? in
            guard case let .directory(place) = destination else { return nil }
            return place.path
        }
        let preferences = AppPreferences.shared
        prefetch(places + preferences.favorites + Array(preferences.recents.prefix(8)))
    }

    private func freshListing(in path: String) -> Listing? {
        guard let listing = cache.object(forKey: path as NSString) else { return nil }
        guard Date().timeIntervalSince(listing.date) < 15 else { return nil }
        return listing
    }

    @objc private func invalidate() {
        worker?.cancel()
        worker = nil
        activePath = nil
        pending.removeAll()
        cache.removeAllObjects()
    }
}
