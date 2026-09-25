import FilaBackendKit
import Foundation

/// The fixed sidebar places a local root can offer, and the identities the
/// user's ordering and hiding are stored under. Persisted raw values — keep
/// them stable when adding a preset.
public enum LocalPreset: Int, CaseIterable, Codable, Sendable {
    case root = 0, bootstrap = 1, applications = 2, mobile = 3
    case pictures = 4, music = 5, inbox = 6, trash = 7
}

/// Everything the local backend remembers: the shared file preferences plus
/// the local-only preset order. Sidebar presets are a local concept — a share
/// has no bootstrap and no trash of this kind — so they are not in
/// `FileBackendPreferences`.
public struct LocalFilePreferences: Codable, Equatable, Sendable {
    public var files: FileBackendPreferences
    /// The user's order, with any preset they never moved appended in the
    /// declared order by the backend at read time.
    public var presetOrder: [LocalPreset]
    public var hiddenPresets: Set<LocalPreset>
    /// The relocated install root the favourites were last checked against.
    /// roothide and rootless both randomize it per jailbreak, so a favourite
    /// saved under the old one is moved to the new one when a daemon reports
    /// a different root. Nil until a relocated daemon has answered once.
    public var favoritesInstallRoot: String?

    public init(
        files: FileBackendPreferences = FileBackendPreferences(),
        presetOrder: [LocalPreset] = [],
        hiddenPresets: Set<LocalPreset> = [],
        favoritesInstallRoot: String? = nil,
    ) {
        self.files = files
        self.presetOrder = presetOrder
        self.hiddenPresets = hiddenPresets
        self.favoritesInstallRoot = favoritesInstallRoot
    }

    /// Saved order first, then every preset the user never placed, so a
    /// preset added in an update appears without being lost.
    public var orderedPresets: [LocalPreset] {
        var seen = Set<LocalPreset>()
        return (presetOrder + LocalPreset.allCases).filter { seen.insert($0).inserted }
    }
}
