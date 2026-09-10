import Darwin
import FilaFileOps
import FilaLog
import FilaProtocol
import Foundation

/// A directory descriptor the backend opened and this process reads.
///
/// The module's convention for a handed-back descriptor is
/// `DescriptorIO.readAndClose`: one call, then it is gone. A listing is a
/// stream, so its descriptor has to outlive the call that made it, and a
/// stream nobody ever starts must still close it — hence an owner. Closed
/// once, by the reader when the listing ends or is abandoned, and by
/// `deinit` if nothing else got there.
public final class DirectoryDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The descriptor while open, -1 after `close()`.
    public var fileDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    /// Only the reader closes: it blocks in `getattrlistbulk` on the raw
    /// number, and a close from anywhere else while that call is out would
    /// let the kernel hand the number to whatever opens next, which the
    /// reader would then read as the directory.
    func close() {
        lock.lock()
        let open = descriptor
        descriptor = -1
        lock.unlock()
        if open >= 0 {
            Darwin.close(open)
        }
    }

    deinit {
        close()
    }
}

/// The directory listing the app reads for itself, over a descriptor the
/// daemon opened as root.
///
/// `filad` opens the directory and hands the descriptor over; nothing
/// else crosses XPC. `getattrlistbulk(2)` then answers with complete
/// entries — name, kind, size, times, owner, mode, flags — about four
/// hundred per call, which is what a page of the daemon's listing carried
/// after a `readdir` and one `fstatat` per entry, without the per-page
/// round trip and without the daemon doing the work: eight calls for three
/// thousand entries, against three thousand `fstatat`s and six pages.
///
/// The descriptor is root's: `readdir` on it would enumerate names this
/// process cannot otherwise see. The attributes are not — the kernel
/// checks the caller's own credentials on each `getattrlistbulk`, so in a
/// directory this process cannot search the first call fails with `EACCES`
/// before any entry, and the caller lists through the daemon instead. This
/// path can therefore only ever show less than the daemon's listing, never
/// more; the daemon canonicalises the path in `open` exactly as it does in
/// `list`; and nothing the guard governs is a read.
///
/// A symlink's target is read here and followed once, as the daemon does,
/// so the browser knows whether it leads to a folder. Following is a path
/// walk as this process, so a link into a folder only root may enter comes
/// back `EACCES`; `resolveLink` asks the backend about that one path.
///
/// Two places the bulk read and the daemon's `fstatat` would disagree.
/// A mount point: `getattrlistbulk` describes the directory the mount
/// covers, `stat` the mounted volume's root, so `/private/var` would show
/// the stub's dates and size — the reader asks for the mount status and
/// takes one `fstatat` for such an entry, a handful per volume. A folder's
/// link count: the filesystem's own (one, on APFS) where `stat` reports
/// two. The properties screen reads its node through `details`, so
/// nothing shows that one.
///
/// The read loop is a detached task, so the blocking calls — 0.6–0.8 ms
/// each on a warm directory, 60–75 ms for the first on a cold one — occupy
/// one width of the cooperative pool for the listing's length. One per
/// browser on screen, at most the daemon's eight per peer; the daemon's
/// own queue did the same work before, in its process.
public enum DirectoryBulkReader {
    /// Bytes per `getattrlistbulk` call. An entry is about a hundred and
    /// fifty bytes with the attributes asked for here, so this is roughly
    /// four hundred entries: the first batch lands fast, and a long
    /// directory streams.
    private static let bufferByteCount = 64 * 1024

    /// The directory's entries in batches, closing `directory` when the
    /// stream ends or its consumer lets go.
    ///
    /// The reader runs ahead of its consumer: the stream's buffer is
    /// unbounded, and `getattrlistbulk` is cheap enough that a warm
    /// directory can be entirely in that buffer before the list has drawn
    /// its first rows. `limit` bounds it: the reader stops once it has
    /// yielded more than that, delivering whole the batch that crosses it,
    /// so a consumer with the same cap sees the crossing and can call the
    /// listing truncated; a directory of exactly `limit` entries ends
    /// normally. An empty batch — every entry in a call gone before its
    /// attributes were read — is not yielded.
    ///
    /// A failure before any entry is the caller's cue to list another way.
    /// `code` follows the shared errno mapping; branch on `systemError`,
    /// not on `code`, because `EACCES` here is the kernel refusing this
    /// process, not the daemon refusing the app.
    public static func entries(
        in directory: DirectoryDescriptor,
        path: String,
        limit: Int = .max,
        resolveLink: (@Sendable (_ name: String) async -> FileKind?)? = nil
    ) -> AsyncThrowingStream<[FileNode], Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                defer { directory.close() }
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferByteCount, alignment: 8)
                defer { buffer.deallocate() }
                do {
                    var yielded = 0
                    while !Task.isCancelled, yielded <= limit {
                        guard var batch = try read(directory.fileDescriptor, path: path, into: buffer) else { break }
                        guard !batch.isEmpty else { continue }
                        if let resolveLink {
                            await resolve(&batch, through: resolveLink)
                        }
                        guard !Task.isCancelled else { break }
                        continuation.yield(batch.map(\.node))
                        yielded += batch.count
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One entry as read, and whether following its link was refused —
    /// which is not the same as the link dangling: a dangling link is not
    /// asked about.
    private struct Entry {
        var node: FileNode
        var followRefused = false
    }

    /// The refused links of a batch, asked about a few at a time: each ask
    /// is a round trip to the daemon, and a folder of links into root's
    /// directories would otherwise pay them one after another before its
    /// first row.
    private static func resolve(_ batch: inout [Entry], through resolveLink: @escaping @Sendable (String) async -> FileKind?) async {
        let refused = batch.indices.filter { batch[$0].followRefused }
        guard !refused.isEmpty else { return }
        let names = refused.map { batch[$0].node.name }
        let kinds = await withTaskGroup(of: (Int, FileKind?).self, returning: [Int: FileKind?].self) { group in
            var next = 0
            func start() {
                guard next < names.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await resolveLink(names[index])) }
            }
            for _ in 0 ..< 4 { start() }
            var kinds: [Int: FileKind?] = [:]
            while let (index, kind) = await group.next() {
                kinds[index] = kind
                start()
            }
            return kinds
        }
        for (position, index) in refused.enumerated() {
            batch[index].node.link?.resolvedKind = kinds[position] ?? nil
        }
    }

    /// One call: the next entries, or nil at the end of the directory.
    private static func read(_ descriptor: Int32, path: String, into buffer: UnsafeMutableRawPointer) throws -> [Entry]? {
        guard descriptor >= 0 else { throw FilaFailure(errno: EBADF, path: path) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = group([
            bit(ATTR_CMN_RETURNED_ATTRS), bit(ATTR_CMN_ERROR), bit(ATTR_CMN_NAME), bit(ATTR_CMN_OBJTYPE),
            bit(ATTR_CMN_CRTIME), bit(ATTR_CMN_MODTIME), bit(ATTR_CMN_ACCTIME),
            bit(ATTR_CMN_OWNERID), bit(ATTR_CMN_GRPID), bit(ATTR_CMN_ACCESSMASK), bit(ATTR_CMN_FLAGS), bit(ATTR_CMN_FILEID),
        ])
        request.dirattr = group([
            bit(ATTR_DIR_LINKCOUNT), bit(ATTR_DIR_MOUNTSTATUS), bit(ATTR_DIR_ALLOCSIZE), bit(ATTR_DIR_DATALENGTH),
        ])
        request.fileattr = group([bit(ATTR_FILE_LINKCOUNT), bit(ATTR_FILE_ALLOCSIZE), bit(ATTR_FILE_DATALENGTH)])
        // `FSOPT_PACK_INVAL_ATTRS` puts every requested attribute in the
        // buffer whether or not the volume supports it, so the layout is
        // fixed and `parse` walks it as such. `FSOPT_NOFOLLOW` is belt and
        // braces: a bulk read has no path to follow, and what it says about a
        // link is about the link.
        var count: Int32
        var error: Int32 = 0
        repeat {
            count = getattrlistbulk(
                descriptor, &request, buffer, bufferByteCount, UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
            )
            error = count < 0 ? Darwin.errno : 0
            // A cancelled listing in a process taking signals — a profiler's
            // `SIGPROF` — must not spin here; it ends as a listing ends.
        } while error == EINTR && !Task.isCancelled
        guard count >= 0 else {
            if error == EINTR { return nil }
            throw FilaFailure(errno: error, path: path)
        }
        guard count > 0 else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var unreadable = 0
        let end = buffer + bufferByteCount
        var cursor = buffer
        for index in 0 ..< Int(count) {
            let start = cursor
            // The kernel wrote the lengths, so these hold; a length that did
            // not would walk the parse off the buffer, and the check is free.
            // The directory offset has moved past every entry of this call,
            // so what a bad length leaves behind is gone from the listing.
            guard start + MemoryLayout<UInt32>.size <= end else { unreadable += Int(count) - index; break }
            let length = Int(cursor.loadUnaligned(as: UInt32.self))
            guard length >= MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size, start + length <= end else {
                unreadable += Int(count) - index
                break
            }
            cursor = start + length
            switch parse(start + MemoryLayout<UInt32>.size, upTo: cursor, in: descriptor, of: path) {
            case let .entry(entry): entries.append(entry)
            case .removed: break
            case .unreadable: unreadable += 1
            }
        }
        if unreadable > 0 {
            FilaLog.verbose("list \(path): \(unreadable) of \(count) entries not readable through getattrlistbulk")
            // Every entry of a call unreadable is the volume packing
            // differently, not a name or two lost to a race: the listing
            // fails, and a caller that has nothing yet lists another way.
            if entries.isEmpty {
                throw FilaFailure(errno: ENOTSUP, path: path)
            }
        }
        return entries
    }

    private enum Parsed {
        case entry(Entry)
        /// Gone between the directory read and the attribute read.
        case removed
        /// Not laid out as `parse` expects; nothing in it can be trusted.
        case unreadable
    }

    /// The attributes of one entry, in the order the kernel packs them:
    /// the returned set, then the requested attributes in bit order —
    /// common, then directory, then file. Within the common group every
    /// requested field is there whether or not the volume supports it
    /// (`FSOPT_PACK_INVAL_ATTRS`): the returned set says which values mean
    /// anything, not which fields are present — `/dev` does not support
    /// `ATTR_CMN_CRTIME`, and reading the set as presence would slide every
    /// later field. The directory group is packed for a directory and the
    /// file group for everything else — a link, a socket, a device — by the
    /// object type, which is the kernel's own rule; the returned set's group
    /// bits say only which of those values are valid, and a volume that
    /// validates none of a group still packs it. Fields are four-byte
    /// aligned, and every one asked for here is a multiple of four bytes,
    /// so no padding is walked; a two-byte attribute would need it.
    ///
    /// `ATTR_CMN_ERROR` is out of bit order: when requested it is packed
    /// for every entry, right after the returned set, and it is in the
    /// returned set whenever it is packed — which is the test made here, so
    /// the walk is right either way. An entry whose error is not zero —
    /// removed between the directory read and the attribute read — carries
    /// nothing after its name and is skipped, as the daemon skips one whose
    /// `fstatat` fails.
    ///
    /// The walk checks itself: the name is the first variable-length
    /// field, so after the last fixed field the cursor must be exactly on
    /// it. A filesystem that packed differently would put every value in
    /// the wrong field; the check turns that into an entry not listed, and
    /// `read` turns a call of nothing but those into a failure.
    private static func parse(
        _ base: UnsafeMutableRawPointer, upTo end: UnsafeMutableRawPointer, in descriptor: Int32, of path: String
    ) -> Parsed {
        var field = base
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        if returned.has(common: ATTR_CMN_ERROR) {
            guard field + MemoryLayout<UInt32>.size <= end else { return .unreadable }
            let error = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if error != 0 { return .removed }
        }
        guard returned.has(common: ATTR_CMN_NAME), returned.has(common: ATTR_CMN_OBJTYPE) else { return .unreadable }
        // The name's reference and the object type sit first; the type says
        // which group follows the common one, and so how long the fixed
        // fields are. Those, then the name's bytes, must fit the entry.
        let namePosition = field
        guard field + MemoryLayout<attrreference_t>.size + MemoryLayout<fsobj_type_t>.size <= end else { return .unreadable }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        field += MemoryLayout<attrreference_t>.size
        let kind = FileKind(objectType: field.loadUnaligned(as: fsobj_type_t.self))
        field += MemoryLayout<fsobj_type_t>.size
        let isDirectory = kind == .directory
        let fixedByteCount = MemoryLayout<attrreference_t>.size + MemoryLayout<fsobj_type_t>.size
            + 3 * MemoryLayout<timespec>.size + 4 * MemoryLayout<UInt32>.size + MemoryLayout<UInt64>.size
            + (isDirectory ? 2 * MemoryLayout<UInt32>.size + 2 * MemoryLayout<Int64>.size
                : MemoryLayout<UInt32>.size + 2 * MemoryLayout<Int64>.size)
        guard namePosition + fixedByteCount <= end else { return .unreadable }
        let nameStart = namePosition + Int(reference.attr_dataoffset)
        let nameByteCount = Int(reference.attr_length)
        guard nameStart == namePosition + fixedByteCount, nameByteCount > 0, nameStart + nameByteCount <= end else {
            return .unreadable
        }
        // The name is read as bytes, within the length the kernel gave —
        // never past it, whether or not the terminator it also wrote is
        // there — and repaired to a String, as the daemon's listing does: a
        // name that is not valid UTF-8 still appears, and is still not
        // actionable — see `filaChild`.
        let nameBytes = UnsafeRawBufferPointer(start: nameStart, count: nameByteCount)
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
        guard !name.isEmpty else { return .unreadable }
        var created = nextTime(&field, valid: returned.has(common: ATTR_CMN_CRTIME))
        var modified = nextTime(&field, valid: returned.has(common: ATTR_CMN_MODTIME))
        var accessed = nextTime(&field, valid: returned.has(common: ATTR_CMN_ACCTIME))
        var owner = nextUInt32(&field, valid: returned.has(common: ATTR_CMN_OWNERID))
        var group = nextUInt32(&field, valid: returned.has(common: ATTR_CMN_GRPID))
        var access = nextUInt32(&field, valid: returned.has(common: ATTR_CMN_ACCESSMASK))
        var flags = nextUInt32(&field, valid: returned.has(common: ATTR_CMN_FLAGS))
        var inode = nextUInt64(&field, valid: returned.has(common: ATTR_CMN_FILEID))
        var links: UInt32 = 0
        var allocated: Int64 = 0
        var size: Int64 = 0
        var isMountPoint = false
        if isDirectory {
            links = nextUInt32(&field, valid: returned.has(directory: ATTR_DIR_LINKCOUNT))
            let mountStatus = nextUInt32(&field, valid: returned.has(directory: ATTR_DIR_MOUNTSTATUS))
            isMountPoint = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            allocated = nextInt64(&field, valid: returned.has(directory: ATTR_DIR_ALLOCSIZE))
            size = nextInt64(&field, valid: returned.has(directory: ATTR_DIR_DATALENGTH))
        } else {
            links = nextUInt32(&field, valid: returned.has(file: ATTR_FILE_LINKCOUNT))
            allocated = nextInt64(&field, valid: returned.has(file: ATTR_FILE_ALLOCSIZE))
            size = nextInt64(&field, valid: returned.has(file: ATTR_FILE_DATALENGTH))
        }
        if isMountPoint {
            // The bulk read described the directory under the mount; what
            // the user sees at that name is the mounted volume's root, and
            // that is what the daemon's `fstatat` reported.
            var mounted = stat()
            if fstatat(descriptor, name, &mounted, 0) == 0 {
                created = seconds(mounted.st_birthtimespec)
                modified = seconds(mounted.st_mtimespec)
                accessed = seconds(mounted.st_atimespec)
                owner = mounted.st_uid
                group = mounted.st_gid
                access = UInt32(mounted.st_mode)
                flags = mounted.st_flags
                inode = mounted.st_ino
                links = UInt32(mounted.st_nlink)
                allocated = Int64(mounted.st_blocks) * 512
                size = Int64(mounted.st_size)
            } else {
                // The row then describes the covered directory — its inode,
                // its dates — which is the answer to "why does this mount
                // show that date", so it is said.
                let refused = FilaFailure(errno: Darwin.errno, path: (path as NSString).appendingPathComponent(name))
                FilaLog.verbose("list \(path): mount point \(name) described as the directory it covers, \(FilaLog.describe(refused))")
            }
        }

        var link: SymbolicLink?
        var followRefused = false
        if kind == .symbolicLink {
            (link, followRefused) = readLink(name, in: descriptor)
        }
        let node = FileNode(
            name: name,
            kind: kind,
            size: size,
            allocatedSize: allocated,
            modified: modified,
            created: created,
            accessed: accessed,
            // `getattrlist(2)`: only the permission bits of the access mask
            // are valid, the rest is to be ignored — APFS happens to return
            // the type bits too. The kind supplies them; `.unknown` supplies
            // none, so a type the enum does not name loses its `S_IFMT`.
            mode: mode_t(access & 0o7777) | kind.typeBits,
            ownerID: owner,
            groupID: group,
            systemFlags: flags,
            linkCount: UInt64(links),
            inode: inode,
            link: link
        )
        return .entry(Entry(node: node, followRefused: followRefused))
    }

    private static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    /// Where a link points and what is there — nil `resolvedKind` for a
    /// dangling link, and `true` beside it when following was refused
    /// rather than impossible, so the backend can be asked.
    ///
    /// The twin of `filaReadSymbolicLink` in FilaFileOps, with the refusal
    /// told apart; a change to one is a change to the other.
    private static func readLink(_ name: String, in descriptor: Int32) -> (SymbolicLink?, Bool) {
        var target = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = target.withUnsafeMutableBufferPointer { readlinkat(descriptor, name, $0.baseAddress, $0.count - 1) }
        guard length >= 0 else { return (nil, false) }
        target[length] = 0
        var resolved = stat()
        if fstatat(descriptor, name, &resolved, 0) == 0 {
            return (SymbolicLink(target: String(cString: target), resolvedKind: FileKind(modeBits: resolved.st_mode)), false)
        }
        let refused = Darwin.errno == EACCES || Darwin.errno == EPERM
        return (SymbolicLink(target: String(cString: target), resolvedKind: nil), refused)
    }

    /// The `ATTR_*` macros import as `Int32` or `UInt32` by their top bit;
    /// a group is their union.
    private static func bit(_ attribute: some BinaryInteger) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: attribute)
    }

    private static func group(_ attributes: [attrgroup_t]) -> attrgroup_t {
        attributes.reduce(0, |)
    }

    // The cursor advances over every field; `valid` only decides whether
    // the value is kept.

    private static func nextTime(_ field: inout UnsafeMutableRawPointer, valid: Bool) -> Double {
        let seconds = field.loadUnaligned(as: Int.self)
        let nanoseconds = field.loadUnaligned(fromByteOffset: MemoryLayout<Int>.size, as: Int.self)
        field += MemoryLayout<timespec>.size
        return valid ? Double(seconds) + Double(nanoseconds) / 1_000_000_000 : 0
    }

    private static func nextUInt32(_ field: inout UnsafeMutableRawPointer, valid: Bool) -> UInt32 {
        let value = field.loadUnaligned(as: UInt32.self)
        field += MemoryLayout<UInt32>.size
        return valid ? value : 0
    }

    private static func nextUInt64(_ field: inout UnsafeMutableRawPointer, valid: Bool) -> UInt64 {
        let value = field.loadUnaligned(as: UInt64.self)
        field += MemoryLayout<UInt64>.size
        return valid ? value : 0
    }

    private static func nextInt64(_ field: inout UnsafeMutableRawPointer, valid: Bool) -> Int64 {
        let value = field.loadUnaligned(as: Int64.self)
        field += MemoryLayout<Int64>.size
        return valid ? value : 0
    }
}

private extension attribute_set_t {
    func has(common attribute: some BinaryInteger) -> Bool {
        commonattr & attrgroup_t(truncatingIfNeeded: attribute) != 0
    }

    func has(directory attribute: some BinaryInteger) -> Bool {
        dirattr & attrgroup_t(truncatingIfNeeded: attribute) != 0
    }

    func has(file attribute: some BinaryInteger) -> Bool {
        fileattr & attrgroup_t(truncatingIfNeeded: attribute) != 0
    }
}

extension FileKind {
    /// From `getattrlist`'s `fsobj_type_t` — the `vtype` values.
    init(objectType: fsobj_type_t) {
        switch objectType {
        case 1: self = .regular // VREG
        case 2: self = .directory // VDIR
        case 3: self = .blockDevice // VBLK
        case 4: self = .characterDevice // VCHR
        case 5: self = .symbolicLink // VLNK
        case 6: self = .socket // VSOCK
        case 7: self = .fifo // VFIFO
        default: self = .unknown
        }
    }

    /// The `S_IF*` bits this kind carries in `st_mode`.
    var typeBits: mode_t {
        switch self {
        case .regular: S_IFREG
        case .directory: S_IFDIR
        case .symbolicLink: S_IFLNK
        case .fifo: S_IFIFO
        case .socket: S_IFSOCK
        case .blockDevice: S_IFBLK
        case .characterDevice: S_IFCHR
        case .unknown: 0
        }
    }
}
