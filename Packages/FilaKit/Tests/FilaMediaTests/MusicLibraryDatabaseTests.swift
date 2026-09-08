@testable import FilaMedia
import Foundation
import SQLite3
import Testing

@Suite("Music library snapshots")
struct MusicLibraryDatabaseTests {
    @Test("Listing and backup include committed WAL data and preserve 64-bit song IDs")
    func readsCommittedWAL() throws {
        try withLibrary { directory, connection, library in
            let tracks = try library.tracks()
            #expect(tracks.count == 1)
            #expect(tracks.first?.id == 9_007_199_254_740_993)
            #expect(tracks.first?.title == "原来的歌曲")
            #expect(tracks.first?.artist == "Artist")
            let destination = directory.appendingPathComponent("backup.sqlitedb")
            try library.backup(to: destination)
            try execute("UPDATE item_extra SET title = 'Changed'", on: connection)
            #expect(try library.tracks().first?.title == "Changed")
            #expect(try MusicLibraryDatabase(path: destination.path).tracks().first?.title == "原来的歌曲")
            #expect(try (FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test("A backup never overwrites an existing file")
    func keepsExistingDestination() throws {
        try withLibrary { directory, _, library in
            let destination = directory.appendingPathComponent("existing")
            let content = Data("keep this".utf8)
            try content.write(to: destination)
            #expect(throws: (any Error).self) { try library.backup(to: destination) }
            #expect(try Data(contentsOf: destination) == content)
        }
    }

    @Test("A missing database is refused without creating an empty library")
    func missingDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(throws: (any Error).self) { try MusicLibraryDatabase(path: path).tracks() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    private func withLibrary(_ body: (URL, OpaquePointer, MusicLibraryDatabase) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fila-music-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlitedb").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        let connection = try #require(handle)
        defer { sqlite3_close(connection) }
        try execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE item (item_pid INTEGER PRIMARY KEY, item_artist_pid INTEGER, album_pid INTEGER, media_type INTEGER, in_my_library INTEGER);
        CREATE TABLE item_extra (item_pid INTEGER PRIMARY KEY, title TEXT);
        CREATE TABLE item_artist (item_artist_pid INTEGER PRIMARY KEY, item_artist TEXT);
        CREATE TABLE album (album_pid INTEGER PRIMARY KEY, album TEXT);
        INSERT INTO item VALUES (9007199254740993, 1, 2, 1, 1);
        INSERT INTO item VALUES (2, 1, 2, 1, 0);
        INSERT INTO item VALUES (3, 1, 2, 2, 1);
        INSERT INTO item_extra VALUES (9007199254740993, '原来的歌曲');
        INSERT INTO item_extra VALUES (2, 'Cached song outside the library');
        INSERT INTO item_extra VALUES (3, 'Movie');
        INSERT INTO item_artist VALUES (1, 'Artist');
        INSERT INTO album VALUES (2, 'Album');
        """, on: connection)
        try body(directory, connection, MusicLibraryDatabase(path: path))
    }

    private func execute(_ sql: String, on connection: OpaquePointer) throws {
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }
}
