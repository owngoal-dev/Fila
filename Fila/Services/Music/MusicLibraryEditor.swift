import FilaLog
import Foundation
import MediaPlayer

/// All writes stay with MusicLibrary, which owns album/artist grouping, sort
/// maps and library notifications. No SQL UPDATE is issued by Fila.
actor MusicLibraryEditor {
    static let shared = MusicLibraryEditor()
    static let databasePath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private var observingLibrary = false

    enum Field: String, CaseIterable, Sendable {
        case title = "Title", artist = "Artist", album = "Album", albumArtist = "AlbumArtist"
        case genre = "Genre", composer = "Composer", year = "Year"
        case trackNumber = "TrackNumber", discNumber = "DiscNumber", comment = "Comment"

        var isNumber: Bool {
            self == .year || self == .trackNumber || self == .discNumber
        }
    }

    struct Details: Sendable {
        let id: Int64
        var values: [Field: String]
        let editableFields: Set<Field>
    }

    func tracks() async throws -> [MusicLibraryTrack] {
        try await authorize()
        if !observingLibrary {
            MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
            observingLibrary = true
        }
        // MediaPlayer resolves the active library and owns the music predicate.
        // Avoid relying on private columns to decide which songs are visible.
        let items = MPMediaQuery.songs().items ?? []
        try Task.checkCancellation()
        FilaLog.info("Music library query returned \(items.count) songs")
        return items.map {
            MusicLibraryTrack(id: Int64(bitPattern: $0.persistentID), title: $0.title ?? "",
                              artist: $0.artist ?? "", album: $0.albumTitle ?? "")
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func deleteTrack(id: Int64) async throws {
        try await authorize()
        do { try nativeLibrary().deleteTrackID(id) }
        catch {
            FilaLog.error("Music library deletion failed: \(error)")
            throw self.error(String(localized: "The song could not be deleted from the music library. Try again."))
        }
    }

    func details(id: Int64) throws -> Details {
        let values: [String: String]
        let native: NativeMusicLibrary
        do {
            native = try nativeLibrary()
            values = try native.values(forTrackID: id)
        } catch { throw unavailable() }
        return Details(id: id, values: Dictionary(uniqueKeysWithValues: Field.allCases.map {
            ($0, values[$0.rawValue] ?? "")
        }), editableFields: Set(native.editableFields.compactMap(Field.init(rawValue:))))
    }

    /// Each action changes one field. A failed field cannot leave unrelated
    /// edits half-applied, and values not edited by the user are never sent.
    func save(id: Int64, field: Field, original: String, value: String) throws -> Details {
        let replacement: Any
        let expected: String
        if field.isNumber {
            guard let number = Int(value), (0 ... 9999).contains(number) else {
                throw error(String(localized: "Enter a whole number from 0 to 9999."))
            }
            replacement = NSNumber(value: number)
            expected = String(number)
        } else {
            guard !value.utf8.contains(0), value.utf8.count <= 16384 else {
                throw error(String(localized:
                    "This value is too long or includes a character that cannot be saved. Change it and try again."))
            }
            replacement = value
            expected = value
        }
        let before = try details(id: id)
        guard before.editableFields.contains(field) else { throw unavailable() }
        guard before.values[field] == original else { throw changed() }
        if expected == original {
            return before
        }

        // The native bridge rereads before writing and catches Objective-C
        // exceptions before they can unwind Swift.
        do {
            try nativeLibrary().setValue(replacement, forField: field.rawValue, trackID: id, expected: original)
        } catch let failure as NSError {
            if failure.domain == "MusicLibrary", failure.code == 2 {
                throw changed()
            }
            throw error(String(localized: "The music library could not save this change. Reopen the song’s details and try again."))
        }
        let saved = try details(id: id)
        guard saved.values[field] == expected else {
            throw error(String(localized: "The change could not be confirmed. Reopen the song’s details to check."))
        }
        return saved
    }

    func authorize() async throws {
        let status: MPMediaLibraryAuthorizationStatus = if MPMediaLibrary.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            MPMediaLibrary.authorizationStatus()
        }
        guard status == .authorized else {
            throw error(String(
                localized: "Fila does not have access to Music. Allow access in Settings, then try again."
            ))
        }
    }

    func nativeLibrary() throws -> NativeMusicLibrary {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            throw error(String(
                localized: "Fila does not have access to Music. Allow access in Settings, then try again."
            ))
        }
        guard FileManager.default.isReadableFile(atPath: Self.databasePath) else { throw unavailable() }
        return try NativeMusicLibrary(expectedDatabasePath: Self.databasePath)
    }

    private func changed() -> NSError {
        error(String(localized: "This song changed while it was open. Reopen its details before editing it."))
    }

    private func unavailable() -> NSError {
        error(String(localized: "Fila cannot edit the music library on this device."))
    }

    func error(_ message: String) -> NSError {
        NSError(domain: "MusicLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
