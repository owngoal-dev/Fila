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

    public init(
        files: FileBackendPreferences = FileBackendPreferences(),
        presetOrder: [LocalPreset] = [],
        hiddenPresets: Set<LocalPreset> = []
    ) {
        self.files = files
        self.presetOrder = presetOrder
        self.hiddenPresets = hiddenPresets
    }

    /// Saved order first, then every preset the user never placed, so a
    /// preset added in an update appears without being lost.
    public var orderedPresets: [LocalPreset] {
        var seen = Set<LocalPreset>()
        return (presetOrder + LocalPreset.allCases).filter { seen.insert($0).inserted }
    }
}
