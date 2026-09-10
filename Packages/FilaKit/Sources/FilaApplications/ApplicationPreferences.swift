import FilaBackendKit
import Foundation

/// What the applications backend remembers: the list's own order and scope,
/// separate from the file list's — an app list sorted by size or date has no
/// meaning.
public struct ApplicationPreferences: Codable, Equatable, Sendable {
    public var sort: AppSort
    public var scope: AppScope

    public init(sort: AppSort = .name, scope: AppScope = .all) {
        self.sort = sort
        self.scope = scope
    }
}

extension AppSort: Codable {}
extension AppScope: Codable {}

/// The keys the app has always written for these two switches: `appSort` and
/// `appScope`, each in its old shape. Only the keys whose value changed are
/// written. The retired `showsApplications` key is left where it is rather
/// than deleted: the feature is no longer optional, and a downgrade should
/// still find the user's old answer.
@MainActor
public final class ApplicationPreferencesDefaults: DefaultStorage {
    public typealias Value = ApplicationPreferences

    private let defaults: UserDefaults
    private var known: ApplicationPreferences?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> ApplicationPreferences? {
        let value = ApplicationPreferences(
            sort: defaults.string(forKey: "appSort").flatMap(AppSort.init) ?? .name,
            scope: defaults.string(forKey: "appScope").flatMap(AppScope.init) ?? .all
        )
        known = value
        return value
    }

    public func save(_ value: ApplicationPreferences) throws {
        if known?.sort != value.sort {
            defaults.set(value.sort.rawValue, forKey: "appSort")
        }
        if known?.scope != value.scope {
            defaults.set(value.scope.rawValue, forKey: "appScope")
        }
        known = value
    }
}
