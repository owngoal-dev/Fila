import Darwin
import FilaProtocol
import Foundation

/// One open directory, read a page at a time.
///
/// The `DIR *` stays open between pages, and that is the whole point: it is the
/// only cursor that keeps its meaning while entries appear and disappear
/// underneath it. An index into a snapshot would silently skip or repeat
/// entries the moment the directory changed, and on a jailbroken device the
/// interesting directories change constantly.
///
/// Nothing here ever holds the whole directory. A page is at most
/// `FilaProtocol.directoryPageEntryCount` entries, and a directory with 100k of
/// them costs the daemon one descriptor.
public final class DirectoryListing {
    /// The directory as `FilaPath.canonical` resolved it.
    public let path: String
    public private(set) var lastUsed = Date()

    private var handle: UnsafeMutablePointer<DIR>?

    public init(path: String) throws {
        let resolved = try FilaPath.canonical(path)
        guard let handle = opendir(resolved) else {
            throw FilaFailure(errno: Darwin.errno, path: resolved)
        }
        self.path = resolved
        self.handle = handle
    }

    /// The next page, and whether the directory is exhausted.
    public func nextPage(
        limit: Int = FilaProtocol.directoryPageEntryCount
    ) throws -> (entries: [FileNode], isFinal: Bool) {
        lastUsed = Date()
        guard let handle else { return ([], true) }
        let descriptor = dirfd(handle)

        var entries: [FileNode] = []
        entries.reserveCapacity(limit)
        while entries.count < limit {
            // `readdir` answers NULL for the end of the directory and for an
            // I/O error alike, and the two must not look the same: a listing
            // truncated by a bad block would otherwise be reported as a
            // complete directory, and the client would show a folder as empty.
            Darwin.errno = 0
            guard let record = readdir(handle) else {
                let code = Darwin.errno
                guard code == 0 else { throw FilaFailure(errno: code, path: path) }
                return (entries, true)
            }
            guard let child = filaChild(record, in: descriptor) else { continue }
            entries.append(FileNode(name: child.name, metadata: child.metadata, at: descriptor, named: child.name))
        }
        return (entries, false)
    }

    public func close() {
        guard let handle else { return }
        closedir(handle)
        self.handle = nil
    }

    deinit { close() }
}

/// One directory entry, named and stat'd, or nil for `.`, `..` and anything
/// that vanished between the `readdir` and the `fstatat`.
///
/// The name is read as bytes for the `fstatat` and as a `String` for the wire,
/// so a name that is not valid UTF-8 is still stat'ed correctly and still
/// appears in the listing. It is *not* actionable: the String repairs the bad
/// bytes to U+FFFD, an XPC string cannot carry the originals, and a path the
/// client rebuilds from the repaired name names nothing. Making those files
/// operable needs a raw-bytes field on the wire.
func filaChild(_ record: UnsafeMutablePointer<dirent>, in directory: Int32) -> (name: String, metadata: stat)? {
    var entry = record.pointee
    return withUnsafePointer(to: &entry.d_name) { field in
        field.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { name -> (String, stat)? in
            let text = String(cString: name)
            guard text != ".", text != ".." else { return nil }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return (text, metadata)
        }
    }
}

/// The listings one peer holds open.
///
/// Not thread-safe, and does not need to be: the daemon drives it from the
/// control queue, which is the only queue a peer's requests arrive on.
public final class ListingRegistry {
    private var listings: [UInt64: DirectoryListing] = [:]
    private var nextIdentifier: UInt64 = 1

    public init() {}

    public var count: Int {
        listings.count
    }

    /// A page of `directory`, and the cursor for the next one — zero when the
    /// directory is finished and the handle is already closed.
    ///
    /// A cursor of zero starts a new listing.
    public func page(
        directory: String,
        cursor: UInt64,
        limit: Int = FilaProtocol.directoryPageEntryCount
    ) throws -> (entries: [FileNode], cursor: UInt64) {
        closeIdleListings()
        let resolved = try FilaPath.canonical(directory)

        let identifier: UInt64
        let listing: DirectoryListing
        if cursor == 0 {
            listing = try DirectoryListing(path: resolved)
            evictOldestIfFull()
            identifier = nextIdentifier
            nextIdentifier &+= 1
            listings[identifier] = listing
        } else {
            // A cursor the daemon no longer has: it idled out, or it was
            // evicted for a newer listing. Saying so is better than silently
            // restarting the directory from the top, which would look to the
            // client like entries repeating forever.
            guard let existing = listings[cursor], existing.path == resolved else {
                throw FilaFailure(code: .invalidRequest, systemError: ESTALE, path: directory)
            }
            identifier = cursor
            listing = existing
        }

        let page = try listing.nextPage(limit: limit)
        guard !page.isFinal else {
            listing.close()
            listings[identifier] = nil
            return (page.entries, 0)
        }
        return (page.entries, identifier)
    }

    public func closeAll() {
        for listing in listings.values {
            listing.close()
        }
        listings.removeAll()
    }

    /// The app abandons a listing whenever the user navigates away and nothing
    /// tells the daemon about it, so a listing that has not been asked for its
    /// next page goes.
    ///
    /// Pruned when the peer next asks for anything and when it disconnects,
    /// rather than on a timer: a timer would keep the daemon's run loop alive
    /// for something whose worst case is a handful of descriptors held by the
    /// one process that is allowed to talk to us.
    private func closeIdleListings() {
        let now = Date()
        for (identifier, listing) in listings
            where now.timeIntervalSince(listing.lastUsed) > FilaProtocol.listingIdleTimeoutSeconds
        {
            listing.close()
            listings[identifier] = nil
        }
    }

    private func evictOldestIfFull() {
        while listings.count >= FilaProtocol.concurrentListingsPerPeer {
            guard let oldest = listings.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
            oldest.value.close()
            listings[oldest.key] = nil
        }
    }
}
