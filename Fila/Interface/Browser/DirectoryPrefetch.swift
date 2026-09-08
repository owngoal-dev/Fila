import FilaProtocol
import UIKit

/// Disposable presentation data. Every destination still lists again after appearing.
/// One bounded worker yields to foreground reads. Cancelling it releases the
/// listing cursor and discards late data before it can enter the cache.
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
    private var foregroundReads: Set<UUID> = []
    private static let entryLimit = 2048

    private init() {
        cache.countLimit = 16
        cache.totalCostLimit = Self.entryLimit * 4
        for name in [Notification.Name.filaJobFinished, UIApplication.didReceiveMemoryWarningNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: nil)
        }
    }

    func entries(in path: String) -> [FileNode]? {
        freshListing(in: path)?.entries
    }

    func store(_ entries: [FileNode], in path: String) {
        guard entries.count <= Self.entryLimit else {
            cache.removeObject(forKey: path as NSString)
            return
        }
        cache.setObject(Listing(entries), forKey: path as NSString, cost: max(1, entries.count))
    }

    /// A foreground request owns a token, so an old cancellation cannot resume
    /// speculation while a newer request is still receiving pages.
    func beginForegroundRead() -> UUID {
        let id = UUID()
        foregroundReads.insert(id)
        cancelPending()
        return id
    }

    func endForegroundRead(_ id: UUID) {
        foregroundReads.remove(id)
    }

    func cancelPending() {
        worker?.cancel()
        worker = nil
        activePath = nil
        pending.removeAll()
    }

    func prefetch(_ paths: [String]) {
        guard foregroundReads.isEmpty, FileSession.shared.hello != nil,
              UIApplication.shared.applicationState != .background else { return }
        var seen = Set<String>()
        let candidates = Array(paths.filter { seen.insert($0).inserted && freshListing(in: $0) == nil }.prefix(4))
        if let activePath, !candidates.contains(activePath) { cancelPending() }
        pending = candidates.filter { $0 != activePath }
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            // Scrolling and push animations get the file service first.
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            while !pending.isEmpty {
                let path = pending.removeFirst()
                guard freshListing(in: path) == nil else { continue }
                activePath = path
                // This nonisolated async function assembles bounded data on the
                // generic executor. Only cache publication returns to MainActor.
                let entries = try? await DirectoryReader.entries(in: path, session: .shared, limit: Self.entryLimit)
                guard !Task.isCancelled else { return }
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
        cancelPending()
        cache.removeAllObjects()
    }
}
