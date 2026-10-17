import Darwin
import FilaLog
import Foundation

/// One URL session to one WebDAV server, and the rules every request on it
/// follows.
///
/// **Bytes are streamed, never held.** A download is written into the
/// caller's descriptor as each piece arrives, and an upload is read from
/// its descriptor a piece at a time into a bound stream pair, so a transfer
/// of any size keeps the same few hundred kilobytes in memory. Everything
/// else — a listing, a refusal's body — is collected, and a reply larger
/// than `collectLimit` is cut off as `invalidResponse` instead of growing
/// without bound.
///
/// **The account is answered, not volunteered.** The password goes out
/// only in reply to the server's own challenge for this session, Basic or
/// Digest, and a challenge that comes back after it was answered once is a
/// refused account rather than a loop. A redirect to another scheme, host
/// or port is refused, so a server cannot hand the session — and with it
/// the account — to somewhere else.
///
/// **Cancelling the caller cancels the request.** The URL session task is
/// cancelled, and nothing is written to a descriptor after the call has
/// returned or thrown.
final class WebDAVTransport: NSObject, @unchecked Sendable {
    /// The most a collected reply may hold. A listing of tens of thousands
    /// of entries fits; a server streaming garbage does not.
    static let collectLimit = 32 << 20
    /// What one upload read moves into the bound stream at a time.
    static let uploadChunk = 256 << 10

    let baseURL: URL
    private let username: String?
    private let password: String?
    private let lock = NSLock()
    private var session: URLSession?
    private var exchanges: [Int: Exchange] = [:]

    init(baseURL: URL, username: String?, password: String?, requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "wiki.qaq.fila.webdav"
        // The session holds its delegate until `close` invalidates it, which
        // is what the owning service's `disconnect` does.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Ends the session: every request in flight fails as `disconnected`,
    /// and every later one fails without being sent.
    func close() {
        lock.lock()
        let session = session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }

    // MARK: - Requests

    /// Where a reply's body goes.
    enum Sink {
        /// Kept, up to `collectLimit`.
        case collect
        /// A success's body is written into `descriptor`, with the running
        /// count and the reply's `Content-Length`, when it gave one,
        /// reported to `progress`; a refusal's body is collected.
        case descriptor(Int32, progress: @Sendable (_ written: Int64, _ expected: Int64?) -> Void)
    }

    /// The body an upload reads, from the start, every time the session
    /// asks for it — a retry after an authentication challenge asks again.
    struct Upload: Sendable {
        let descriptor: Int32
        let size: Int64
        let progress: @Sendable (Int64) -> Void
    }

    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        var isSuccess: Bool {
            (200 ..< 300).contains(status)
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Sends `request` and waits for its whole reply. Throws only for a
    /// failure of the exchange itself; an HTTP refusal is a reply.
    func send(_ request: URLRequest, upload: Upload? = nil, sink: Sink = .collect) async throws -> Reply {
        let exchange = Exchange(sink: sink, upload: upload)
        let task = try makeTask(request, upload: upload, exchange: exchange)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exchange.start(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            // The caller's cancellation is a cancellation, not the
            // `cancelled` transport error it turned into.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// A task for `request`, registered for the delegate's callbacks. Not
    /// started: the caller resumes it once its continuation is in place.
    private func makeTask(_ request: URLRequest, upload: Upload?, exchange: Exchange) throws -> URLSessionTask {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw WebDAVError.disconnected }
        let task: URLSessionTask
        if let upload {
            var streamed = request
            streamed.setValue(String(upload.size), forHTTPHeaderField: "Content-Length")
            task = session.uploadTask(withStreamedRequest: streamed)
        } else {
            task = session.dataTask(with: request)
        }
        exchanges[task.taskIdentifier] = exchange
        exchange.task = task
        return task
    }

    /// `path` under the server's root, each component percent-encoded so a
    /// name is always one name: `%`, `?`, `#` and `;` included. A collection
    /// ends in `/`, which servers that redirect `/folder` to `/folder/` need.
    func url(for components: [String], collection: Bool) -> URL {
        var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var path = url.percentEncodedPath
        for component in components {
            path += component.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters) ?? component
            path += "/"
        }
        if !collection, !components.isEmpty {
            path.removeLast()
        }
        url.percentEncodedPath = path
        return url.url!
    }

    /// RFC 3986's unreserved characters: everything else in a name is encoded.
    private static let pathCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[task.taskIdentifier]
    }

    private func finish(_ task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges.removeValue(forKey: task.taskIdentifier)
    }

    private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
}

// MARK: - Delegate

extension WebDAVTransport: URLSessionDataDelegate {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            // Only the server this session was made for, only once: a second
            // challenge is the server refusing what it was given, and the
            // default handling then delivers its 401 as the reply.
            guard let username, challenge.previousFailureCount == 0,
                  let original = task.originalRequest?.url, sameOrigin(original, baseURL)
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: username, password: password ?? "", persistence: .forSession))
        default:
            // Server trust stays the system's decision.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        // Nil delivers the redirect itself as the reply. Only a read is
        // followed, and only on this server: the session rewrites a
        // redirected request, and a PROPFIND, MOVE or DELETE could lose its
        // method, its body or its Depth, Destination and If-Match on the
        // way. The callers handle the 3xx themselves.
        let method = task.originalRequest?.httpMethod ?? "GET"
        guard method == "GET" || method == "HEAD", let url = request.url, sameOrigin(url, baseURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void,
    ) {
        completionHandler(exchange(for: task)?.makeBodyStream())
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend _: Int64,
    ) {
        exchange(for: task)?.upload?.progress(totalBytesSent)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        exchange(for: dataTask)?.expect(response.expectedContentLength)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        let status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if !exchange.receive(data, status: status) {
            dataTask.cancel()
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = finish(task) else { return }
        exchange.complete(response: task.response as? HTTPURLResponse, error: error)
    }
}

// MARK: - Exchange

/// One request's state between the delegate's callbacks, which arrive one
/// at a time on the session's serial queue.
private final class Exchange: @unchecked Sendable {
    let sink: WebDAVTransport.Sink
    let upload: WebDAVTransport.Upload?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebDAVTransport.Reply, Error>?
    /// The outcome, when the task finished before `start` installed the
    /// continuation: a caller cancelled between creating the task and
    /// resuming it gets its answer from here instead of waiting forever.
    private var outcome: Result<WebDAVTransport.Reply, Error>?
    private var collected = Data()
    private var written: Int64 = 0
    /// Why this side stopped the task: a descriptor that refused a write,
    /// a reply past the limit. Reported instead of the cancellation it caused.
    private var failure: WebDAVError?
    private var writer: BodyWriter?
    private var expectedLength: Int64?
    /// The task this exchange belongs to, so a failure on this side — the
    /// upload's source refusing a read — stops it at once rather than at
    /// the request timeout.
    weak var task: URLSessionTask?

    init(sink: WebDAVTransport.Sink, upload: WebDAVTransport.Upload?) {
        self.sink = sink
        self.upload = upload
    }

    func start(_ continuation: CheckedContinuation<WebDAVTransport.Reply, Error>) {
        lock.lock()
        guard let outcome else {
            self.continuation = continuation
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(with: outcome)
    }

    /// A fresh stream over the upload from its first byte. The previous
    /// one, if the session asked before, is abandoned and its writer stops.
    func makeBodyStream() -> InputStream? {
        guard let upload else { return nil }
        lock.lock()
        writer?.stop()
        let next = BodyWriter(upload: upload) { [weak self] error in
            self?.fail(error)
        }
        writer = next
        lock.unlock()
        return next.start()
    }

    func expect(_ length: Int64) {
        lock.lock()
        expectedLength = length >= 0 ? length : nil
        lock.unlock()
    }

    /// False when the task must stop.
    func receive(_ data: Data, status: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return false }
        if case let .descriptor(descriptor, progress) = sink, (200 ..< 300).contains(status) {
            do {
                try Self.write(data, to: descriptor)
            } catch let error as WebDAVError {
                failure = error
                return false
            } catch {
                failure = .descriptorWrite(code: EIO)
                return false
            }
            written += Int64(data.count)
            progress(written, expectedLength)
            return true
        }
        guard collected.count + data.count <= WebDAVTransport.collectLimit else {
            failure = .invalidResponse
            return false
        }
        collected.append(data)
        return true
    }

    private func fail(_ error: WebDAVError) {
        lock.lock()
        if failure == nil {
            failure = error
        }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func complete(response: HTTPURLResponse?, error: Error?) {
        let result: Result<WebDAVTransport.Reply, Error>
        lock.lock()
        writer?.stop()
        writer = nil
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            result = .success(.init(status: response.statusCode, headers: headers, body: collected))
        } else {
            result = .failure(WebDAVError.invalidResponse)
        }
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            outcome = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Every byte of `data`, retrying a short or interrupted write.
    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw WebDAVError.descriptorWrite(code: errno)
                }
                offset += result
            }
        }
    }
}

/// Feeds one upload body into a bound stream pair from a thread of its own:
/// `pread` from the start of the descriptor, exactly `size` bytes, blocking
/// on the stream when the session has not taken the last piece yet.
private final class BodyWriter: @unchecked Sendable {
    private let upload: WebDAVTransport.Upload
    private let onFailure: (WebDAVError) -> Void
    private let lock = NSLock()
    private var stopped = false

    init(upload: WebDAVTransport.Upload, onFailure: @escaping (WebDAVError) -> Void) {
        self.upload = upload
        self.onFailure = onFailure
    }

    func start() -> InputStream? {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: WebDAVTransport.uploadChunk, inputStream: &input, outputStream: &output)
        guard let input, let output else { return nil }
        let thread = Thread { [self] in run(output) }
        thread.name = "wiki.qaq.fila.webdav-upload"
        thread.start()
        return input
    }

    /// Stops feeding. The stream is only ever touched by the writer's own
    /// thread — a stream pair is not safe to close from another — so a
    /// write blocked on it returns when the session closes its end, which
    /// it does when the task ends, and the writer then reads nothing more.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run(_ output: OutputStream) {
        output.open()
        defer { output.close() }
        var buffer = [UInt8](repeating: 0, count: WebDAVTransport.uploadChunk)
        var offset: Int64 = 0
        while offset < upload.size, !isStopped {
            let wanted = Int(min(Int64(buffer.count), upload.size - offset))
            let got = buffer.withUnsafeMutableBytes { pread(upload.descriptor, $0.baseAddress, wanted, off_t(offset)) }
            if got < 0, errno == EINTR {
                continue
            }
            guard got > 0 else {
                // A read error, or a file shorter than the size it was sent
                // with: the server must not publish what arrived.
                onFailure(.descriptorRead(code: got < 0 ? errno : EIO))
                return
            }
            var sent = 0
            while sent < got {
                if isStopped {
                    return
                }
                let result = buffer.withUnsafeBytes { output.write($0.baseAddress!.assumingMemoryBound(to: UInt8.self) + sent, maxLength: got - sent) }
                guard result > 0 else { return }
                sent += result
            }
            offset += Int64(got)
        }
    }
}
