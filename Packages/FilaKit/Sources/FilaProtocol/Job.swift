import Foundation

/// Work that takes long enough to need progress and cancellation.
///
/// The three that change the filesystem run on libSystem — `copyfile(3)`,
/// `removefile(3)`, `renameat(2)`, `clonefile(2)` — whose state callbacks give
/// progress and a `QUIT` return for free, and whose memory is flat regardless
/// of how big the tree is. That last property is why jobs are allowed to live
/// inside the 6 MB daemon at all, and it is the bar `.search` had to clear to
/// join them.
public enum FilaJobKind: UInt64, Sendable, Codable {
    case copy = 1
    case move = 2
    case delete = 3

    /// Walk a tree and report the entries whose names match. The only kind that
    /// touches nothing, and the only one whose answers arrive on a message of
    /// their own — see `FilaOperation.searchResult`.
    case search = 4

    /// Write `sources` into the archive named by `destination`, and read the
    /// archive at `sources[0]` into the directory `destination`. Both run in
    /// `fila-archive`, a helper the daemon spawns: libarchive allocates by
    /// content size and cannot live inside the daemon's 6 MB, and a job that
    /// runs in the app dies with it — so the bytes stay out of `filad`, and
    /// the work outlives the screen that asked for it. See `ArchiveOptions`.
    case compress = 5
    case extract = 6

    /// Put a trashed item back at its recorded origin, without replacing anything.
    case restore = 7

    public var isArchive: Bool { self == .compress || self == .extract }
}

/// One job as the client asks for it.
public struct JobRequest: Sendable, Hashable, Codable {
    public var kind: FilaJobKind
    /// Absolute paths. Multi-select is the normal case, not the exception.
    public var sources: [String]
    /// The directory the sources land in. Ignored by `.delete` and `.restore`;
    /// restore reads each exact destination from its origin record.
    public var destination: String?
    /// `.delete` only: move into the backend's trash instead of unlinking.
    /// The daemon owns where the trash is; the client only says whether it
    /// wants one.
    public var useTrash: Bool
    /// Identifies a trash batch across copies. Restore may require this identity.
    public var trashID: UUID?
    /// Replace what is already at the destination. When false a collision fails
    /// the job with `EEXIST` and the client asks the user what to do.
    public var overwrite: Bool
    /// The "I know what I am doing" switch. Honoured for every protected node
    /// except the volume root and the bootstrap root, which have no recovery
    /// path on a phone.
    public var overrideGuard: Bool

    /// `.search` only, and required by it: `sources` are the roots to walk and
    /// this is what to look for. Nil for every other kind.
    public var query: SearchQuery?

    /// `.compress` and `.extract` only, and required by them.
    public var archive: ArchiveOptions?

    public init(
        kind: FilaJobKind,
        sources: [String],
        destination: String? = nil,
        useTrash: Bool = false,
        trashID: UUID? = nil,
        overwrite: Bool = false,
        overrideGuard: Bool = false,
        query: SearchQuery? = nil,
        archive: ArchiveOptions? = nil
    ) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.useTrash = useTrash
        self.trashID = trashID
        self.overwrite = overwrite
        self.overrideGuard = overrideGuard
        self.query = query
        self.archive = archive
    }
}

/// What a running job reports.
///
/// Progress is best-effort and the totals can move: they come from a walk the
/// daemon does as it goes, not from a pre-pass that would double the work. A
/// client shows a bar when the totals are known and a spinner when they are not.
public enum JobEvent: Sendable, Hashable {
    case progress(JobProgress)
    /// The job is over. `code` is `.success`, `.cancelled`, or a failure, and
    /// nothing more arrives for this id.
    case completed(FilaFailure)

    public var isFinal: Bool {
        if case .completed = self { return true }
        return false
    }
}

public struct JobProgress: Sendable, Hashable, Codable {
    public var bytesDone: Int64
    /// Zero while the total is still unknown.
    public var bytesTotal: Int64
    /// Entries the job has finished with. A search moves no bytes and counts
    /// every entry it looked at here, which is what an item is for it; both
    /// byte fields stay zero, because a count of directories is not a count of
    /// bytes and `fraction` would turn one into a percentage of the other.
    public var itemsDone: Int64
    public var itemsTotal: Int64
    /// What the job is touching right now, for the label under the bar. For a
    /// search this is the directory being read, which is the honest answer to
    /// "how far has it got".
    public var currentPath: String

    public init(bytesDone: Int64, bytesTotal: Int64, itemsDone: Int64, itemsTotal: Int64, currentPath: String) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.currentPath = currentPath
    }

    /// Nil while the total is unknown — which is a different thing from zero,
    /// and the difference is a bar versus a spinner. Bytes when the job counted
    /// them; items when it only counted members, as an extraction does.
    public var fraction: Double? {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        guard itemsTotal > 0 else { return nil }
        return min(1, Double(itemsDone) / Double(itemsTotal))
    }
}
