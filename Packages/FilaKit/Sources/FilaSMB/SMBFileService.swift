import Darwin
import FilaBackendKit
import FilaLog
import Foundation
import SMBClient

/// The neutral file contract over one SMB share.
///
/// Every path is relative to the share root and goes on the wire as
/// backslash-joined components; nothing here resolves, normalises or cases
/// a name, and a component the protocol could read as more than a name is
/// refused before it leaves the process. A directory is listed one server
/// response at a time and a file is read in bounded chunks straight into
/// the caller's descriptor, so no operation holds more than one response
/// in memory whatever the size on the other end.
public final class SMBFileService: FileService, @unchecked Sendable {
    /// The most read in one request. Servers offer up to 8 MiB; one
    /// megabyte keeps a transfer's memory flat and its cancellation prompt.
    public static let readChunk: UInt32 = 1 << 20

    let connection: SMBConnection
    /// What `changes(in:)` polls through. Main-actor, as every observation
    /// owner is: the subscriptions are UI state.
    public let observation: RemoteDirectoryObservation
    private var lostHandler: UUID?

    init(connection: SMBConnection, observation: RemoteDirectoryObservation) {
        self.connection = connection
        self.observation = observation
    }

    /// A service over `profile` with `password`, polling every `interval`.
    public convenience init(
        profile: SMBProfile,
        password: String?,
        pollInterval: TimeInterval = RemoteDirectoryObservation.pollInterval,
        connectTimeout: TimeInterval = 20,
        requestTimeout: TimeInterval = 30
    ) {
        let configuration = SMBConnection.Configuration(
            host: profile.host,
            port: profile.port,
            share: profile.share,
            domain: profile.domain,
            username: profile.username,
            password: password
        )
        self.init(
            connection: SMBConnection(
                configuration: configuration, connectTimeout: connectTimeout, requestTimeout: requestTimeout
            ),
            observation: RemoteDirectoryObservation(interval: pollInterval)
        )
    }

    /// Starts watching the session: a lost session ends every change
    /// stream so its subscribers list again on a fresh one. Idempotent.
    func installObservation() async {
        guard lostHandler == nil else { return }
        let observation = observation
        lostHandler = await connection.onSessionLost { reason in
            Task { @MainActor in observation.finishAll(throwing: reason) }
        }
    }

    /// Closes the session and ends every change stream: what the backend
    /// does when its profile is edited away or removed.
    public func disconnect() async {
        await connection.close()
        await MainActor.run { observation.finishAll(throwing: SMBError.disconnected) }
    }

    /// Hints subscribers of `directories` that this process changed them.
    @MainActor
    public func invalidate(_ directories: [ServicePath]) {
        observation.invalidate(directories.map(\.description))
    }

    // MARK: - FileService

    public func list(_ directory: ServicePath) async throws -> FileListing {
        let wire = try Self.wirePath(directory)
        await installObservation()
        let connection = connection
        return FileListing {
            let cursor = ListingCursor(connection: connection, wire: wire)
            return FileListing.Source(
                next: { try await cursor.next() },
                close: { await cursor.close() }
            )
        }
    }

    public func details(_ path: ServicePath) async throws -> FileEntry {
        let wire = try Self.wirePath(path)
        let stat = try await connection.perform("details", path: path.description) { client in
            try await client.fileStat(path: wire)
        }
        return FileEntry(
            name: path.name ?? connection.configuration.share,
            kind: stat.isDirectory ? .directory : .file,
            size: stat.isDirectory ? nil : Int64(clamping: stat.size),
            modified: Self.date(stat.lastWriteTime),
            isHidden: stat.isHidden || (path.name?.hasPrefix(".") ?? false)
        )
    }

    public func copyContents(
        of path: ServicePath,
        to descriptor: Int32,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let wire = try Self.wirePath(path)
        let handle = try await connection.perform("open", path: path.description) { client in
            let response = try await client.session.create(
                desiredAccess: [.genericRead],
                fileAttributes: [],
                shareAccess: [.read],
                createDisposition: .open,
                createOptions: [],
                name: wire
            )
            return SMBConnection.Handle(client: client, fileId: response.fileId, size: response.endOfFile)
        }
        let expected = Int64(clamping: handle.size)
        var offset: UInt64 = 0
        progress(TransferProgress(completed: 0, expected: expected))
        do {
            while offset < handle.size {
                try Task.checkCancellation()
                let chunkLength = min(Self.readChunk, UInt32(clamping: handle.size - offset))
                let start = offset
                let chunk = try await connection.perform("read", on: handle, path: path.description) { client in
                    let response = try await client.session.read(fileId: handle.fileId, offset: start, length: chunkLength)
                    return ReadChunk(data: response.buffer, endOfFile: NTStatus(response.header.status) == .endOfFile)
                }
                if chunk.data.isEmpty { break }
                try Self.write(chunk.data, to: descriptor)
                offset += UInt64(chunk.data.count)
                progress(TransferProgress(completed: Int64(clamping: offset), expected: expected))
                if chunk.endOfFile { break }
            }
        } catch {
            await close(handle)
            throw error
        }
        await close(handle)
    }

    public func changes(in directory: ServicePath) async throws -> AsyncThrowingStream<Void, Error> {
        _ = try Self.wirePath(directory)
        await installObservation()
        let service = self
        return await observation.subscribe(directory.description) {
            let entry = try await service.details(directory)
            // What moves when an entry is added, removed or renamed. A
            // server that reports no time reports nothing to compare, and
            // the poll then never hints; the listing on appearance and the
            // app's own operations still refresh such a folder.
            return "\(entry.modified?.timeIntervalSince1970 ?? 0)"
        }
    }

    // MARK: - Pieces

    private struct ReadChunk: Sendable {
        let data: Data
        let endOfFile: Bool
    }

    private func close(_ handle: SMBConnection.Handle) async {
        do {
            _ = try await connection.perform("close", on: handle) { client in
                try await client.session.close(fileId: handle.fileId)
            }
        } catch {
            // A handle on a retired session is already closed.
        }
    }

    /// The wire form of `path`: components joined with `\`, empty at the
    /// root. A component is refused when SMB could read it as more than
    /// one name.
    static func wirePath(_ path: ServicePath) throws -> String {
        for component in path.components {
            guard !component.contains(where: { Self.reserved.contains($0) }) else {
                throw SMBError.invalidName(component)
            }
        }
        return path.components.joined(separator: "\\")
    }

    private static let reserved: Set<Character> = ["\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// Seconds between the FILETIME epoch (1601) and the Unix one.
    private static let fileTimeEpochOffset: Double = 11_644_473_600

    /// A FILETIME of zero is "no time", not 1601.
    static func date(_ date: Date) -> Date? {
        date.timeIntervalSince1970 <= -fileTimeEpochOffset + 1 ? nil : date
    }

    /// The same, from the raw 100-nanosecond count the listing carries.
    static func date(fileTime raw: UInt64) -> Date? {
        guard raw != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(raw) / 10_000_000 - fileTimeEpochOffset)
    }

    /// Every byte of `data`, retrying a short or interrupted write.
    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SMBError.descriptorWrite(code: errno)
                }
                written += result
            }
        }
    }
}

public enum SMBShares {
    /// The disk shares on `profile`'s server for its account with
    /// `password`, for the setup screen; the profile's own share need not
    /// exist yet. See `SMBConnection.listShares`.
    public static func list(profile: SMBProfile, password: String?, timeout: TimeInterval = 20) async throws -> [String] {
        try await SMBConnection.listShares(SMBConnection.Configuration(
            host: profile.host, port: profile.port, share: profile.share,
            domain: profile.domain, username: profile.username, password: password
        ), timeout: timeout)
    }
}

/// One directory's pages, pulled one server response at a time.
///
/// The handle opens on the first `next` and closes when the server says
/// there is nothing more, when the consumer stops, or when the session it
/// belongs to is retired — in which case the next page fails as
/// `disconnected` and the consumer lists again on the new session.
actor ListingCursor {
    private let connection: SMBConnection
    private let wire: String
    private var handle: SMBConnection.Handle?
    private var restart = true
    private var finished = false

    init(connection: SMBConnection, wire: String) {
        self.connection = connection
        self.wire = wire
    }

    func next() async throws -> [FileEntry]? {
        guard !finished else { return nil }
        let handle = try await open()
        let wire = wire
        let restart = restart
        let page = try await connection.perform("list", on: handle, path: wire) { client in
            let page = try await client.session.queryDirectoryPage(fileId: handle.fileId, restart: restart)
            return ListingPage(files: page.files.map(SMBEntry.init), hasMore: page.hasMore)
        }
        self.restart = false
        let entries = page.files.filter { $0.name != "." && $0.name != ".." }.map(\.entry)
        if !page.hasMore {
            finished = true
            await close()
            if entries.isEmpty { return nil }
        }
        return entries
    }

    func close() async {
        finished = true
        guard let handle else { return }
        self.handle = nil
        do {
            _ = try await connection.perform("close", on: handle) { client in
                try await client.session.close(fileId: handle.fileId)
            }
        } catch {
            // A handle on a retired session is already closed.
        }
    }

    private func open() async throws -> SMBConnection.Handle {
        if let handle { return handle }
        let wire = wire
        let handle = try await connection.perform("open", path: wire) { client in
            let response = try await client.session.create(
                desiredAccess: [.readData, .readAttributes, .synchronize],
                fileAttributes: [.directory],
                shareAccess: [.read, .write, .delete],
                createDisposition: .open,
                createOptions: [.directoryFile],
                name: wire
            )
            return SMBConnection.Handle(client: client, fileId: response.fileId, size: 0)
        }
        self.handle = handle
        return handle
    }
}

private struct ListingPage: Sendable {
    let files: [SMBEntry]
    let hasMore: Bool
}

/// One directory entry as the server sent it, mapped once.
struct SMBEntry: Sendable {
    let name: String
    let entry: FileEntry

    init(_ information: FileDirectoryInformation) {
        name = information.fileName
        let attributes = information.fileAttributes
        let kind: FileEntry.Kind
        if attributes.contains(.reparsePoint) {
            // A junction, a symlink, a mount point: something the server
            // follows on our behalf. Which of those it is, SMB2 does not
            // say without another request; what it opens as is known.
            kind = .symbolicLink(resolved: attributes.contains(.directory) ? .directory : .file)
        } else if attributes.contains(.directory) {
            kind = .directory
        } else {
            kind = .file
        }
        entry = FileEntry(
            name: name,
            kind: kind,
            size: attributes.contains(.directory) ? nil : Int64(clamping: information.endOfFile),
            modified: SMBFileService.date(fileTime: information.lastWriteTime),
            isHidden: attributes.contains(.hidden) || name.hasPrefix(".")
        )
    }
}
