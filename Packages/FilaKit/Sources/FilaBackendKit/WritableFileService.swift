import Foundation

/// What happens when the name a write publishes at is already taken.
///
/// The default is to fail: a copy that silently replaces what was there is
/// a delete the user did not ask for. Replacement is offered only where the
/// backend can do it as the kernel does — the old content gone and the new
/// content there in one step, never a window with neither — and every
/// conformer documents what it can and cannot honour.
public enum PublishPolicy: Sendable, Equatable {
    /// The name must be free; an occupied one is `WriteFailure.alreadyExists`.
    case failIfExists
    /// A file at the name is replaced. A directory is never replaced by a
    /// file: that is `WriteFailure.notEmpty` or `.alreadyExists`, whichever
    /// the backend reports.
    case replace
}

/// The refusals a transfer decides on. Everything else a write can throw is
/// the backend's own error, shown to the user as it is.
///
/// A conformer maps its native errors onto these where it can tell them
/// apart, and only there: an SMB status the module cannot classify stays an
/// SMB error, because a wrong classification would make the transfer act
/// on it.
public enum WriteFailure: Error, Sendable, Equatable {
    /// Something is already at `path` and the policy did not allow
    /// replacing it.
    case alreadyExists(ServicePath)
    /// `path` is not there: a parent that went away, a source that moved.
    case notFound(ServicePath)
    /// A directory that still has entries, or a file where a directory was
    /// expected to be replaced.
    case notEmpty(ServicePath)
    /// The publication request was sent and its reply never came. The
    /// content may or may not be at `path`; the caller lists the directory
    /// again and never retries the publication or removes the source on the
    /// strength of this.
    case publicationUnknown(ServicePath)
}

/// The destination side of a copy or move: the four writes a transfer
/// needs, with the publication semantics each one promises. Not a generic
/// command bag — a backend that cannot keep one of these promises does not
/// conform, and controllers offer nothing they cannot deliver.
public protocol WritableFileService: FileService {
    /// Creates one directory. Its parent must exist; an occupied name is
    /// `WriteFailure.alreadyExists`, whatever is at it.
    func createDirectory(_ directory: ServicePath) async throws

    /// Writes `size` bytes read from `descriptor` — a regular file, open for
    /// reading, positioned at its start — and publishes them at
    /// `destination` under `policy`.
    ///
    /// The bytes go to a private temporary beside the destination first and
    /// are published in one step once every one of them is written and the
    /// temporary is closed, so `destination` never names a half-written
    /// file. A failure before publication removes the temporary; a
    /// publication whose reply was lost is `WriteFailure.publicationUnknown`
    /// and leaves whatever the server has. `progress` reports bytes written,
    /// never a made-up total. Cancellation stops the write, removes the
    /// temporary where it still can, and throws `CancellationError`. The
    /// caller keeps the descriptor open until this returns and closes it.
    func writeFile(
        from descriptor: Int32,
        size: Int64,
        to destination: ServicePath,
        policy: PublishPolicy,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws

    /// Removes one file, or a link as the link. A directory is refused.
    func removeFile(_ path: ServicePath) async throws

    /// Removes one directory only while it is empty; one that has entries
    /// is `WriteFailure.notEmpty`, and its entries are never touched.
    func removeEmptyDirectory(_ path: ServicePath) async throws

    /// Renames within this backend: what a move between two folders of
    /// the same share is. `policy` decides an occupied `destination`, with
    /// the same promise `writeFile` makes for it.
    func move(_ source: ServicePath, to destination: ServicePath, policy: PublishPolicy) async throws
}

/// A file service that can hand out a descriptor on a file: the local one.
///
/// A transfer whose source offers this reads the source straight into the
/// destination's write, with no staging copy in between. Every other
/// source is staged through `copyContents` first.
public protocol DescriptorFileService: FileService {
    /// A read-only descriptor on the regular file at `path`, positioned at
    /// its start. The caller owns it and closes it. A directory or a
    /// special file is refused.
    func openForReading(_ path: ServicePath) async throws -> Int32
}
