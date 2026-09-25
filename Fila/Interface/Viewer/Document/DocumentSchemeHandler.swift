import Foundation
import WebKit

/// Serves one document to the web view showing it, read from its descriptor.
///
/// The document is the main resource of `fila-document://document/<name>`,
/// sent under the MIME type WebKit converts it by. Nothing else is served: any
/// other URL on the scheme fails, so a converted page cannot use the scheme
/// to ask for a file of its choosing.
///
/// Reads are `pread(2)` on a queue of their own, a chunk at a time, and are
/// handed to WebKit on the main thread with a few chunks in flight: a large
/// document is never whole in this process, and a stopped load stops reading.
final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "fila-document"

    /// The document's URL. Its last path component is the file's name, which
    /// WebKit gives the converter.
    let url: URL

    private let file: DescriptorFile
    private let name: String
    private let mimeType: String
    private let queue = DispatchQueue(label: "wiki.qaq.fila.document-reader", qos: .userInitiated)
    /// Loads in progress, by task. Main thread only.
    private var loads: [ObjectIdentifier: Load] = [:]

    private static let chunkByteCount = 1024 * 1024
    private static let chunksInFlight = 4

    init(file: DescriptorFile, name: String, mimeType: String) {
        self.file = file
        self.name = name
        self.mimeType = mimeType
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "document"
        components.path = "/" + name
        // A name is one path component and never empty, so this cannot fail;
        // the fallback only keeps the type non-optional.
        url = components.url ?? URL(string: "\(Self.scheme)://document/document")!
        super.init()
    }

    /// Whether `url` is the document, or a place inside it. Compared decoded,
    /// not as a string: WebKit may escape a name — brackets, `%`, CJK — other
    /// than `URLComponents` did, and the same file must still be the same URL.
    func isDocument(_ url: URL) -> Bool {
        url.scheme?.lowercased() == Self.scheme && url.host == "document" && url.path == "/" + name
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let requested = task.request.url, isDocument(requested) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let load = Load()
        loads[ObjectIdentifier(task)] = load
        let byteCount = file.byteCount
        task.didReceive(URLResponse(
            url: requested,
            mimeType: mimeType,
            expectedContentLength: Int(byteCount),
            textEncodingName: nil,
        ))

        let file = file
        queue.async { [weak self] in
            let slots = DispatchSemaphore(value: Self.chunksInFlight)
            var offset: Int64 = 0
            while !load.isStopped {
                slots.wait()
                let chunk: Result<Data, Error>
                do {
                    let data = try file.read(at: offset, count: Self.chunkByteCount)
                    // Short of the size it had at open: it shrank under us.
                    chunk = data.isEmpty && offset < byteCount ? .failure(ViewerFailure.readFailed(EIO)) : .success(data)
                } catch {
                    chunk = .failure(error)
                }
                if case let .success(data) = chunk {
                    offset += Int64(data.count)
                }
                let isLast = offset >= byteCount
                DispatchQueue.main.async {
                    defer { slots.signal() }
                    self?.deliver(chunk, isLast: isLast, to: task)
                }
                if case .failure = chunk {
                    return
                }
                if isLast {
                    return
                }
            }
        }
    }

    func webView(_: WKWebView, stop task: WKURLSchemeTask) {
        loads.removeValue(forKey: ObjectIdentifier(task))?.stop()
    }

    /// On the main thread. A task WebKit stopped is never called again:
    /// `WKURLSchemeTask` raises if it is.
    private func deliver(_ chunk: Result<Data, Error>, isLast: Bool, to task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard let load = loads[key], !load.isStopped else { return }
        switch chunk {
        case let .success(data):
            if !data.isEmpty {
                task.didReceive(data)
            }
            if isLast {
                loads.removeValue(forKey: key)
                task.didFinish()
            }
        case let .failure(error):
            loads.removeValue(forKey: key)?.stop()
            task.didFailWithError(error)
        }
    }

    /// One load's stop flag, read by the reading queue.
    private final class Load: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }
}
