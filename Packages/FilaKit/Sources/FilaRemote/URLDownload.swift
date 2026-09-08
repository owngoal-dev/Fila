import FilaProtocol
import Foundation
import FilaFileOps

/// Pulling a URL down to a path, the app's half.
///
/// The split is the same one everything else in this project uses: the app has
/// the bytes and the daemon owns the path. `URLSession` writes into the app's
/// own container — somewhere `mobile` can certainly write — and only then is
/// the file handed to `filad` to be put where the user asked, through the same
/// temporary-then-rename dance as every other write. Nothing downloaded is ever
/// written straight to a root-owned directory by this process, because this
/// process is not allowed to and should not be.
public enum URLDownload {
    /// A running download's progress. `total` is -1 when the server has not
    /// said how big the file is, which for a chunked response it never will.
    public struct Progress: Sendable {
        public let received: Int64
        public let total: Int64
        public let name: String
    }

    public enum Failure: Error, Equatable {
        case unsupportedScheme
        /// The server answered, and the answer was not the file.
        case httpStatus(Int)
        /// The transfer ended without an error and without a body. Nothing is
        /// known to produce it; it is here so the one path that cannot say what
        /// happened does not have to invent a status code that it did not see.
        case noBody
    }

    /// Downloads `url` into `directory` and returns the file it wrote.
    ///
    /// Cancelling the surrounding task cancels the transfer and surfaces as a
    /// `CancellationError`, which is what hooks this into the transfers list's
    /// stop button — the same button that stops a copy.
    ///
    /// Driven through a session delegate and a continuation rather than through
    /// `session.download(from:delegate:)`, and not by preference: the task
    /// delegate that convenience takes is never consulted for
    /// `didWriteData`, so the whole download reported no progress at all. The
    /// long way round is the one that actually reports.
    ///
    /// ponytail: a foreground `URLSession`, not a background one. A background
    /// session survives the app being suspended, and nothing else in this app
    /// does — `filad` cancels a peer's jobs the moment the peer goes away, and
    /// the transfers list says so in as many words. Making the one operation
    /// that could outlive the app behave differently from the eight that cannot
    /// would be a worse lie than the honest one already on screen. Revisit it
    /// if the daemon ever grows queued work of its own.
    public static func fetch(
        _ url: URL,
        into directory: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Failure.unsupportedScheme
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try StorageSpace.requireAvailable(at: FileManager.default.temporaryDirectory.path)
        try StorageSpace.requireAvailable(at: directory.path)

        let observer = DownloadObserver(
            directory: directory,
            fallbackName: suggestedName(for: url),
            report: progress
        )
        let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observer.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The name the file should land under, from the URL alone.
    ///
    /// A URL is written by whoever pasted it, so its last component gets the
    /// same treatment as a request target: no separators, no `.` or `..`, no
    /// empty. `download` is not a good name for `http://host/`, but it is a
    /// name, and the user chose the directory either way.
    public static func suggestedName(for url: URL) -> String {
        sanitize(url.lastPathComponent) ?? "download"
    }

    static func sanitize(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A name made only of separators and dots is not a name. `.` and `..`
        // are the two that would be a path rather than a file.
        guard !cleaned.isEmpty, cleaned.contains(where: { $0 != "_" && $0 != "." }) else { return nil }
        return cleaned
    }
}

/// The session delegate that reports progress and lands the file.
///
/// It owns the continuation, and the two directions it can be settled from —
/// the task finishing and the surrounding task being cancelled — can arrive in
/// either order, so both go through `settle` and the first one wins.
private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// How much has to arrive before the row is told again.
    ///
    /// `didWriteData` fires once per network chunk, and each report walks up
    /// through the operation list and out as a notification the sidebar redraws
    /// on. Unthrottled, a fast connection would spend more time updating a
    /// progress bar than downloading. A quarter of a megabyte is a few bars a
    /// second on a slow link, and the last one is always sent whatever it is.
    private static let reportInterval: Int64 = 256 * 1_024

    private let directory: URL
    private let fallbackName: String
    private let report: @Sendable (URLDownload.Progress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    /// The outcome, when it arrived before anything was waiting for it.
    private var outcome: Result<URL, Error>?
    private var isSettled = false

    /// Only ever touched from the delegate queue, which delivers one task's
    /// callbacks serially.
    private var reported: Int64 = -1

    init(
        directory: URL,
        fallbackName: String,
        report: @escaping @Sendable (URLDownload.Progress) -> Void
    ) {
        self.directory = directory
        self.fallbackName = fallbackName
        self.report = report
    }

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let outcome {
            self.outcome = nil
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func settle(_ result: Result<URL, Error>) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { outcome = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    // MARK: - Delegate

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        do {
            // URLSession writes a system-owned temporary before our final move.
            try StorageSpace.requireAvailable(at: FileManager.default.temporaryDirectory.path)
        } catch {
            settle(.failure(error))
            downloadTask.cancel()
            return
        }
        let isLast = totalBytesWritten == totalBytesExpectedToWrite
        guard isLast || totalBytesWritten - reported >= Self.reportInterval else { return }
        reported = totalBytesWritten
        report(URLDownload.Progress(
            received: totalBytesWritten,
            total: totalBytesExpectedToWrite,
            name: fallbackName
        ))
    }

    /// The temporary is valid only for the duration of this call, so the move
    /// happens here and not a line later.
    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200 ... 299).contains(response.statusCode) {
            // A 404 page landed at the destination as if it were the file is
            // the single worst thing this feature could do.
            settle(.failure(URLDownload.Failure.httpStatus(response.statusCode)))
            return
        }
        let name = downloadTask.response?.suggestedFilename.flatMap(URLDownload.sanitize) ?? fallbackName
        let target = directory.appendingPathComponent(name)
        do {
            // The staging directory is this download's own, so anything already
            // at that name is a leftover of a retry and not the user's file.
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            settle(.success(target))
        } catch {
            settle(.failure(error))
        }
    }

    /// Always called exactly once, error or not — which is what makes it safe
    /// for the failure paths that `didFinishDownloadingTo` never sees.
    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // Success already settled above. If it did not, the server sent a
            // response and no body we could land.
            settle(.failure(URLDownload.Failure.noBody))
            return
        }
        // A cancelled transfer is the user pressing stop, and the transfers
        // list has a case for that which is not "failed".
        if (error as? URLError)?.code == .cancelled {
            settle(.failure(CancellationError()))
        } else {
            settle(.failure(error))
        }
    }
}
