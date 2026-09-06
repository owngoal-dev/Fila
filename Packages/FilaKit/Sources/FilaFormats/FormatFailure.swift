import Foundation

/// Everything a reader or writer in this module can fail with.
///
/// Separate from `FilaFailure` on purpose: that type is the wire's, and every
/// case in it is something the *daemon* decided. Nothing here crosses the wire
/// — a corrupt zip is the app's problem, discovered in the app, and the daemon
/// never sees the bytes at all.
public enum FormatFailure: Error, Sendable, Hashable {
    /// The magic is not what this reader parses. Not a corruption: it is the
    /// answer to "is this a zip", and callers use it to fall through to the
    /// next reader.
    case notRecognised

    /// Structurally broken, with where. Archive and Mach-O headers are
    /// attacker-controlled input — every length in them is checked against the
    /// bytes actually present, and this is what a failed check throws rather
    /// than reading whatever `Data` happens to hold next.
    ///
    /// Also where libarchive's own message lands: *Truncated ZIP file data* says
    /// more about a file than any sentence written here could, so it is carried
    /// through rather than flattened into a generic failure.
    case damaged(String)

    /// Well-formed and understood, but not something this module does: an
    /// encrypted zip member, an lzop stream, an OpenStep plist asked to be
    /// written back.
    case unsupported(String)

    /// Refused before allocating. Reaching for `Data(count:)` with a number
    /// that came out of a file is how a viewer for a 4 GB file becomes a
    /// 4 GB allocation.
    case tooLarge(byteCount: Int64, limit: Int64)

    /// A `ProgressHandler` returned false. Whatever was being written is
    /// half-written and the caller removes it — this module never owns the
    /// destination, so it cannot clean up after itself.
    case cancelled

    /// An encrypted member, and no password or the wrong one. Its own case
    /// because the recovery is its own: ask, and try again.
    case wrongPassword

    /// A syscall failed and left this `errno`.
    case system(errno: Int32)
}

/// How much is done, and the answer to "keep going?".
///
/// Returning false is how the user cancels: the operation throws
/// `FormatFailure.cancelled` and unwinds. Called once per chunk — often enough
/// to move a progress bar, rarely enough that a closure hop costs nothing next
/// to the I/O it is measuring. `bytesTotal` is zero when the total is not
/// knowable in advance, which is a spinner rather than a bar.
public typealias ProgressHandler = (_ bytesDone: Int64, _ bytesTotal: Int64) -> Bool

/// The unit every streaming path in this module moves at.
///
/// Chosen so that the module's memory is a constant the size of a couple of
/// these no matter what it is reading: a 2 GB archive member costs 64 KB, and
/// that property is the entire reason these readers can run in the app over a
/// descriptor instead of anywhere near the daemon.
let chunkByteCount = 64 * 1024

/// Calls `progress` and turns a false into a throw, so the check reads as one
/// line at every call site instead of an `if` that is easy to forget.
func checkCancellation(_ progress: ProgressHandler?, _ done: Int64, _ total: Int64) throws {
    guard let progress else { return }
    guard progress(done, total) else { throw FormatFailure.cancelled }
}
