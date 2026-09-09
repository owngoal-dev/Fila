#if os(iOS)
import CFilaMusicLibrary
import FilaLog
import Foundation
import MediaPlayer
import UIKit

/// All writes stay with MusicLibrary, which owns album/artist grouping, sort
/// maps and library notifications. No SQL UPDATE is issued by Fila.
public actor MusicLibraryEditor {
    public static let shared = MusicLibraryEditor()
    public static let databasePath = "/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private var observingLibrary = false

    public enum Field: String, CaseIterable, Sendable {
        case title = "Title", artist = "Artist", album = "Album", albumArtist = "AlbumArtist"
        case genre = "Genre", composer = "Composer", year = "Year"
        case trackNumber = "TrackNumber", discNumber = "DiscNumber", comment = "Comment"

        public var isNumber: Bool {
            self == .year || self == .trackNumber || self == .discNumber
        }
    }

    public struct Details: Sendable {
        public var values: [Field: String]
        public let editableFields: Set<Field>
    }

    public func tracks() async throws -> [MusicLibraryTrack] {
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
            MusicLibraryTrack(
                id: Int64(bitPattern: $0.persistentID),
                title: $0.title ?? "",
                artist: $0.artist ?? "",
                album: $0.albumTitle ?? "",
                duration: $0.playbackDuration
            )
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func deleteTrack(id: Int64) async throws -> [MusicLibraryTrack] {
        try await authorize()
        do { try nativeLibrary().deleteTrackID(id) }
        catch {
            FilaLog.error("Music library deletion failed: \(error)")
            throw self.error(String(localized: "The song could not be deleted from the music library. Try again.", bundle: MusicLibraryBackend.bundle))
        }
        return try await tracks(confirming: id, present: false)
    }

    nonisolated public static func exportName(title: String, sourcePath: String) -> String {
        MusicExportNaming.name(
            title: title,
            sourcePath: sourcePath,
            untitled: String(localized: "Untitled", bundle: MusicLibraryBackend.bundle)
        )
    }

    public func exportPath(id: Int64) async throws -> String {
        try await authorize()
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: UInt64(bitPattern: id)), forProperty: MPMediaItemPropertyPersistentID
        ))
        guard let item = query.items?.first, !item.hasProtectedAsset, !item.isCloudItem else {
            throw error(String(localized: "Only downloaded, unprotected songs can be exported.", bundle: MusicLibraryBackend.bundle))
        }
        return try nativeLibrary().localPath(forTrackID: id)
    }

    public func artwork(id: Int64, pixelSize: Int) -> Data? {
        guard !Task.isCancelled, MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: UInt64(bitPattern: id)), forProperty: MPMediaItemPropertyPersistentID
        ))
        let image = query.items?.first?.artwork?.image(at: CGSize(width: pixelSize, height: pixelSize))
        guard !Task.isCancelled else { return nil }
        return image?.pngData()
    }

    // MusicLibrary's write completes before MediaPlayer invalidates its cache.
    // Return only a fetched snapshot that actually reflects this operation.
    func tracks(confirming id: Int64, present: Bool) async throws -> [MusicLibraryTrack] {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            let result = try await tracks()
            if result.contains(where: { $0.id == id }) == present { return result }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw error(String(localized: "The music library has not finished updating. Refresh the list to check.", bundle: MusicLibraryBackend.bundle))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func details(id: Int64) throws -> Details {
        let values: [String: String]
        let native: NativeMusicLibrary
        do {
            native = try nativeLibrary()
            values = try native.values(forTrackID: id)
        } catch { throw unavailable() }
        return Details(
            values: Dictionary(uniqueKeysWithValues: Field.allCases.map {
                ($0, values[$0.rawValue] ?? "")
            }),
            editableFields: Set(native.editableFields.compactMap(Field.init(rawValue:)))
        )
    }

    /// Each action changes one field. A failed field cannot leave unrelated
    /// edits half-applied, and values not edited by the user are never sent.
    public func save(id: Int64, field: Field, original: String, value: String) throws -> Details {
        let replacement: Any
        let expected: String
        if field.isNumber {
            guard let number = Int(value), (0 ... 9999).contains(number) else {
                throw error(String(localized: "Enter a whole number from 0 to 9999.", bundle: MusicLibraryBackend.bundle))
            }
            replacement = NSNumber(value: number)
            expected = String(number)
        } else {
            guard !value.utf8.contains(0), value.utf8.count <= 16384 else {
                throw error(String(
                    localized: "This value is too long or includes a character that cannot be saved. Change it and try again.",
                    bundle: MusicLibraryBackend.bundle
                ))
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
            throw error(String(
                localized: "The music library could not save this change. Reopen the song’s details and try again.",
                bundle: MusicLibraryBackend.bundle
            ))
        }
        let saved = try details(id: id)
        guard saved.values[field] == expected else {
            throw error(String(localized: "The change could not be confirmed. Reopen the song’s details to check.", bundle: MusicLibraryBackend.bundle))
        }
        return saved
    }

    public func authorize() async throws {
        let status: MPMediaLibraryAuthorizationStatus = if MPMediaLibrary.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            MPMediaLibrary.authorizationStatus()
        }
        guard status == .authorized else { throw noAccess() }
    }

    func nativeLibrary() throws -> NativeMusicLibrary {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { throw noAccess() }
        guard FileManager.default.isReadableFile(atPath: Self.databasePath) else { throw unavailable() }
        return try NativeMusicLibrary(expectedDatabasePath: Self.databasePath)
    }

    private func noAccess() -> NSError {
        error(String(localized: "Fila does not have access to Music. Allow access in Settings, then try again.", bundle: MusicLibraryBackend.bundle))
    }

    private func changed() -> NSError {
        error(String(localized: "This song changed while it was open. Reopen its details before editing it.", bundle: MusicLibraryBackend.bundle))
    }

    private func unavailable() -> NSError {
        error(String(localized: "Fila cannot edit the music library on this device.", bundle: MusicLibraryBackend.bundle))
    }

    func error(_ message: String) -> NSError {
        NSError(domain: "MusicLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
