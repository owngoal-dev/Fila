import FilaProtocol
import Foundation

/// The slice of `filad` the network features need.
///
/// A protocol rather than `DaemonLink` itself for one reason: this package has
/// to be exercised by `swift test` on a Mac with no daemon, no XPC and no Xcode,
/// and a server that hands out the root filesystem is the last thing in this
/// project that should be shipped untested. There are exactly two conformances
/// — the app's pass-through to `DaemonLink`, and the harness's one over a
/// scratch directory — and there will not be a third.
///
/// Every method here is a daemon operation and nothing else. The server never
/// calls `open(2)`, `unlink(2)` or `stat(2)` itself: the app runs as `mobile`
/// and would serve only what `mobile` can reach, and — far worse — a write that
/// did not travel through the daemon would not meet `FilaGuard`.
public protocol RemoteFileService: Sendable {
    /// Every entry of a directory. The daemon pages; the conformance is what
    /// hides that, because a listing that stops halfway is a listing that hides
    /// the user's files from their own Mac.
    func list(_ directory: String) async throws -> [FileNode]

    func details(of path: String) async throws -> FileDetails

    /// A descriptor the daemon opened. **The caller owns it and closes it.**
    func open(_ path: String, flags: Int32, mode: mode_t) async throws -> Int32

    func create(_ template: NodeTemplate, at path: String) async throws

    /// `exclusive` maps to the kernel's own check-and-move, which is what keeps
    /// a `MOVE` with `Overwrite: F` from destroying a file that appeared between
    /// the check and the call.
    func rename(_ source: String, to destination: String, exclusive: Bool) async throws

    /// Put a temporary the caller has finished writing in place of `target`.
    /// The only way anything in this package writes a file.
    func replaceItem(at target: String, withTemporary temporary: String) async throws

    /// Run a copy, move or delete to completion, or throw. A DAV client is
    /// holding a socket open waiting for the verdict, so unlike everywhere else
    /// in the app this one cannot be fire-and-forget.
    func run(_ job: JobRequest) async throws
}
