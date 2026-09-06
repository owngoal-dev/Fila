import Darwin
import Dispatch
import FilaProtocol
import Foundation

/// A whole-device name search, streamed out of a 6 MB daemon.
///
/// Four properties make that possible, and every one of them is load-bearing:
///
/// - **It does not `stat`.** `readdir`'s `d_type` already says whether an entry
///   is a directory, which is all the walk needs in order to recurse. An
///   `fstatat` happens only for an entry that actually matched, and only
///   because a result row shows a size, a date and a mode. Stat-ing a million
///   entries is what makes a naive whole-device search take minutes.
/// - **It does not allocate per entry.** The name is compared as the C string
///   `readdir` left in its own buffer — `strstr(3)`, `strcasestr(3)` or
///   `fnmatch(3)` — and becomes a Swift `String` only once it has matched. A
///   million `String(cString:)` calls is the other half of the same bill.
/// - **Nothing accumulates.** One `DIR *` and one path string per level of
///   depth, and one batch of at most `FilaProtocol.searchBatchMatchCount`
///   matches that is filled, sent and emptied. There is no result array that
///   grows with the filesystem, which is the whole reason a walk is allowed in
///   here at all.
/// - **It never follows a symlink.** `/var` points into `/private/var`, so a
///   following walk searches half the device twice, and a link pointing at its
///   own ancestor searches it forever. Not following is both the correct answer
///   and the cheap one: cycle detection by inode would need the `stat` this
///   walk exists to avoid.
///
/// Cancellation is checked between entries rather than between directories,
/// because a directory can hold 200k of them and a user who has stopped caring
/// must not wait for it.
///
/// ponytail: `readdir(3)` is one entry per call. `getattrlistbulk(2)` returns
/// many per syscall and can carry the attributes a matched row needs, which
/// would fold the per-match `fstatat` in for free — worth doing if the walk
/// ever shows up as syscall-bound rather than disk-bound.
final class TreeSearch {
    private let query: SearchQuery
    private let job: FileJob
    private let tally: JobTally
    private let deliver: (SearchBatch) -> Void

    /// The needle as C bytes, matched against the C bytes `readdir` hands over.
    private let needle: [CChar]

    /// The one batch in flight, and the only thing here that grows at all.
    private var batch: [SearchMatch] = []
    /// Counts down to `FilaProtocol.searchResultLimit`.
    private var remaining = FilaProtocol.searchResultLimit
    /// Far enough in the past that the first batch is never held back.
    private var lastDelivery = DispatchTime(uptimeNanoseconds: 1)
    private var limits: SearchLimits = []

    init(query: SearchQuery, job: FileJob, tally: JobTally, deliver: @escaping (SearchBatch) -> Void) {
        self.query = query
        self.job = job
        self.tally = tally
        self.deliver = deliver
        needle = Array(query.text.utf8CString)
        batch.reserveCapacity(FilaProtocol.searchBatchMatchCount)
    }

    // MARK: - The walk

    /// Walks everything under `root`, reporting matches as it finds them.
    ///
    /// Throws only for the root itself: the user named that directory, so a root
    /// that cannot be opened is a failed search rather than an empty one.
    /// Everything unreadable *inside* it is skipped and reported through
    /// `SearchLimits.unreadable`.
    func run(root: String) throws {
        // Once the cap is reached the remaining roots are not opened at all.
        // Not an optimisation: a later root that has since been deleted would
        // otherwise throw, and a search that had already found its ten thousand
        // answers would reach the client as an error over a full list.
        guard remaining > 0 else {
            limits.insert(.resultCount)
            return
        }
        let start = try FilaPath.canonical(root)

        var stack: [(handle: UnsafeMutablePointer<DIR>, path: String)] = []
        defer { for level in stack { closedir(level.handle) } }

        /// Opens a child directory, or declines to and says why. Never throws:
        /// one branch of the device must not fail a search of the rest of it.
        func descend(into path: String) {
            guard stack.count < FilaProtocol.searchDepthLimit else {
                limits.insert(.depth)
                return
            }
            guard let handle = opendir(path) else {
                // Mode 000, or a directory that went away between the `readdir`
                // that named it and this call.
                limits.insert(.unreadable)
                return
            }
            stack.append((handle, path))
            tally.beginItem(path)
        }

        guard let handle = opendir(start) else { throw FilaFailure(errno: Darwin.errno, path: start) }
        stack.append((handle, start))
        tally.beginItem(start)

        while let level = stack.last {
            if job.isCancelled { throw FilaFailure(code: .cancelled, path: level.path) }
            guard remaining > 0 else {
                limits.insert(.resultCount)
                return
            }

            // NULL is the end of this directory, or an I/O error on it. Unlike
            // the recursive chown in `AttributeWriter`, a search that reads less
            // than everything shows fewer rows and changes nothing — so a bad
            // directory ends here and the walk carries on, with the shortfall
            // reported rather than hidden.
            Darwin.errno = 0
            guard let record = readdir(level.handle) else {
                if Darwin.errno != 0 { limits.insert(.unreadable) }
                closedir(level.handle)
                stack.removeLast()
                continue
            }

            let name = filaEntryName(record)
            if name.pointee == filaDot {
                // `.`, `..`, and — when the query says so — every dotfile. Not
                // skipping `..` is what would let the walk climb back out of
                // the tree it was given.
                let second = name.advanced(by: 1).pointee
                if second == 0 || (second == filaDot && name.advanced(by: 2).pointee == 0) { continue }
                if !query.includesHidden { continue }
            }
            tally.finishedItem()

            // `d_type` is the whole performance argument: it says "directory"
            // without a stat. Some filesystems answer DT_UNKNOWN, and then —
            // and only then — one `fstatat` for that one entry settles it, and
            // is reused below if the entry also matched.
            let descriptor = dirfd(level.handle)
            let type = record.pointee.d_type
            var metadata = stat()
            var isStated = false
            var isDirectory = type == UInt8(DT_DIR)
            if type == UInt8(DT_UNKNOWN) {
                isStated = fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
                isDirectory = isStated && metadata.st_mode & S_IFMT == S_IFDIR
            }

            if matches(name) {
                // An entry that vanished between the `readdir` and this `fstatat`
                // is dropped: it is no longer there to show.
                if isStated || fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                    let text = String(cString: name)
                    append(SearchMatch(
                        directory: level.path,
                        node: FileNode(name: text, metadata: metadata, at: descriptor, named: text)
                    ))
                }
            }

            // Real directories only. `DT_LNK` is left alone even when it points
            // at one, which is what stops `/var` being searched twice.
            if isDirectory { descend(into: FilaPath.join(level.path, String(cString: name))) }
        }
    }

    // MARK: - Matching

    /// Against the C bytes, never a Swift `String`: this runs once per entry on
    /// the device and `String(cString:)` here would be the search's whole cost.
    private func matches(_ name: UnsafePointer<CChar>) -> Bool {
        needle.withUnsafeBufferPointer { pattern in
            guard let base = pattern.baseAddress else { return false }
            if query.isGlob {
                // A glob is worth its four extra lines: `*.plist` and `libSSL*`
                // are what a file manager's users actually type, and `fnmatch`
                // is already in libSystem with a case-folding flag of its own.
                return fnmatch(base, name, query.isCaseSensitive ? 0 : FNM_CASEFOLD) == 0
            }
            return (query.isCaseSensitive ? strstr(name, base) : strcasestr(name, base)) != nil
        }
    }

    // MARK: - Batching

    private func append(_ match: SearchMatch) {
        batch.append(match)
        remaining -= 1
        // Full, or long enough since the last one that the user deserves to see
        // something: a search of `/` can go a minute between matches, and a
        // list that only fills when a batch does looks like a hung app.
        let now = DispatchTime.now()
        guard batch.count >= FilaProtocol.searchBatchMatchCount
            || now.uptimeNanoseconds &- lastDelivery.uptimeNanoseconds >= 100_000_000 else { return }
        flush(now)
    }

    /// Sends what is in the batch, with every limit the walk has run into so
    /// far. Called when the batch fills, when it has been too long since the
    /// last one, and once more when the search ends — that last call goes out
    /// whether or not there is anything in it, because it is what carries the
    /// limits, and a client that never received them would show a truncated
    /// list as a complete one.
    func flush(_ now: DispatchTime = .now()) {
        lastDelivery = now
        deliver(SearchBatch(matches: batch, limits: limits))
        batch.removeAll(keepingCapacity: true)
    }
}

/// The entry's name, in `readdir`'s own buffer.
///
/// Not `record.pointee`, which copies a kilobyte per entry — a gigabyte of
/// memcpy over a million of them — and not `String(cString:)`, which allocates.
/// Valid until the next `readdir` on the same handle, which is all this walk
/// needs it for.
func filaEntryName(_ record: UnsafeMutablePointer<dirent>) -> UnsafePointer<CChar> {
    UnsafeRawPointer(record).advanced(by: filaEntryNameOffset).assumingMemoryBound(to: CChar.self)
}

/// Read from the layout rather than written down: `dirent` is the kernel's
/// struct, not ours.
private let filaEntryNameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

private let filaDot = CChar(UInt8(ascii: "."))
