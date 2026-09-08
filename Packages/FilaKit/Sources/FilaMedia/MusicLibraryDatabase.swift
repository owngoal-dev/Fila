import Foundation
import SQLite3

/// Reads the system library through SQLite so committed WAL pages are included.
/// System MusicLibrary APIs own edits and their derived indexes.
public struct MusicLibraryDatabase: Sendable {
    public struct Track: Identifiable, Hashable, Sendable {
        public let id: Int64
        public let title: String
        public let artist: String
        public let album: String
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func tracks() throws -> [Track] {
        let database = try openReadOnly()
        defer { sqlite3_close(database) }
        let statement = try prepare("""
            SELECT item.item_pid, item_extra.title,
                   COALESCE(item_artist.item_artist, ''), COALESCE(album.album, '')
            FROM item JOIN item_extra USING(item_pid)
            LEFT JOIN item_artist USING(item_artist_pid)
            LEFT JOIN album USING(album_pid)
            WHERE (item.media_type & 1) != 0 AND item.in_my_library != 0
            ORDER BY item_extra.title COLLATE NOCASE, item.item_pid
            """, in: database)
        defer { sqlite3_finalize(statement) }
        var result: [Track] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure(database) }
            result.append(Track(id: sqlite3_column_int64(statement, 0), title: text(statement, 1),
                                artist: text(statement, 2), album: text(statement, 3)))
        }
    }

    /// The caller supplies a fresh private directory. Never copy a live .db
    /// and its WAL separately: the SQLite backup API captures one snapshot.
    public func backup(to destination: URL) throws {
        let source = try openReadOnly()
        defer { sqlite3_close(source) }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        var completed = false
        defer { if !completed { unlink(destination.path) } }
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            == SQLITE_OK
        else {
            let error = failure(target)
            sqlite3_close(target)
            throw error
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw failure(target) }
        let deadline = Date().addingTimeInterval(15)
        var status: Int32
        repeat {
            if Task.isCancelled || Date() >= deadline {
                sqlite3_backup_finish(backup)
                throw Task.isCancelled ? CancellationError() : failure(source, code: SQLITE_BUSY)
            }
            status = sqlite3_backup_step(backup, 128)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { sqlite3_sleep(20) }
        } while status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            throw failure(target, code: finished == SQLITE_OK ? status : finished)
        }
        let check = try prepare("PRAGMA quick_check", in: target)
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, text(check, 0) == "ok", sqlite3_step(check) == SQLITE_DONE else {
            throw failure(target, code: SQLITE_CORRUPT)
        }
        completed = true
    }

    private func openReadOnly() throws -> OpaquePointer {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let error = failure(database, code: status)
            sqlite3_close(database)
            throw error
        }
        sqlite3_busy_timeout(database, 3000)
        return database
    }

    private func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure(database)
        }
        return statement
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func failure(_ database: OpaquePointer?, code: Int32? = nil) -> NSError {
        let code = code ?? sqlite3_errcode(database)
        return NSError(domain: "SQLite", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: String(
                localized: "The music library is not available. Try again.",
                bundle: .module
            ),
        ])
    }
}
