import FilaBackendKit
import FilaClient
import FilaLog
import Foundation

/// The local backend's preferences, for the screens that still speak in
/// absolute paths. Each call converts at the root boundary and reports a
/// failed save in the log; a preference that did not stick is not worth an
/// alert, and the screen keeps showing the backend's actual state.
extension FileSession {
    var lastDirectoryPath: String {
        local.lastDirectory.map(local.absolutePath) ?? local.rootPath
    }

    func setLastDirectory(_ path: String) {
        guard let location = local.servicePath(forAbsolute: path) else { return }
        record("last directory") { try local.setLastDirectory(location) }
    }

    /// Only explicit use records a directory; appearing or dwelling never does.
    func noteVisit(directory path: String) {
        guard let location = local.servicePath(forAbsolute: path) else { return }
        record("visit") { try local.recordVisit(location) }
    }

    /// A recent that is gone from disk is dropped, not left to fail again.
    func forgetVisit(_ path: String) {
        guard let location = local.servicePath(forAbsolute: path) else { return }
        record("forget visit") { try local.forgetVisit(location) }
    }

    var favoritePaths: [String] {
        local.favorites.map(local.absolutePath)
    }

    /// Newest first; undated history after dated visits, in its stored order.
    func recentPaths(limit: Int) -> [String] {
        Array(local.recents.prefix(limit).map { local.absolutePath($0.path) })
    }

    func isFavorite(_ path: String) -> Bool {
        local.servicePath(forAbsolute: path).map(local.isFavorite) ?? false
    }

    func toggleFavorite(_ path: String) {
        guard let location = local.servicePath(forAbsolute: path) else { return }
        record("favorite") { try local.setFavorite(location, included: !local.isFavorite(location)) }
    }

    var showsHidden: Bool { local.showsHidden }

    func setShowsHidden(_ shows: Bool) {
        record("hidden files") { try local.setShowsHidden(shows) }
    }

    var sortKey: FileSortKey { local.sortKey }
    var sortAscending: Bool { local.sortAscending }

    func setSort(key: FileSortKey, ascending: Bool) {
        record("sort") { try local.setSort(key: key, ascending: ascending) }
    }

    func layout(for path: String) -> BrowserLayout {
        local.servicePath(forAbsolute: path).map(local.layout(for:)) ?? .list
    }

    func setLayout(_ layout: BrowserLayout, for path: String) {
        guard let location = local.servicePath(forAbsolute: path) else { return }
        record("layout") { try local.setLayout(layout, for: location) }
    }

    /// The trash the live backend uses, once the handshake said which.
    var trashDirectory: String? {
        hello.map { local.trashDirectory(backend: $0.backend) }
    }

    private func record(_ what: String, _ change: () throws -> Void) {
        do { try change() }
        catch { FilaLog.error("\(what) not saved: \(error)") }
    }
}
