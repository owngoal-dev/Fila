import Foundation
import NIOHTTP1

/// DAV-specific interpretation of a request head decoded by SwiftNIO.
struct HTTPRequest {
    var method: String
    var target: String
    /// Lowercased names. HTTP header names are case-insensitive and clients
    /// disagree about the casing of `Depth`, `Destination` and `Overwrite`.
    var headers: [String: String]

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Nil for an absent, unparseable *or negative* length. A negative one
    /// reads as zero everywhere downstream, so a `PUT` carrying it would put an
    /// empty file over the target — a truncation nobody asked for.
    var contentLength: Int? {
        guard let value = header("content-length").flatMap({ Int($0.trimmed) }), value >= 0 else { return nil }
        return value
    }

    var isChunked: Bool {
        header("transfer-encoding")?.lowercased().contains("chunked") == true
    }

    var expectsContinue: Bool {
        header("expect")?.lowercased().contains("100-continue") == true
    }

    /// `Depth: 0`, `1` or `infinity`. Absent means infinity by the
    /// specification, which for `PROPFIND` is a whole-filesystem walk — so an
    /// absent header is read as infinity and refused, exactly like a stated one.
    var depth: String {
        header("depth")?.trimmed.lowercased() ?? "infinity"
    }

    /// `Overwrite: F` is the only value that means anything; everything else,
    /// including the header being absent, means T.
    var allowsOverwrite: Bool {
        header("overwrite")?.trimmed.uppercased() != "F"
    }

    /// Keep-alive is the default in HTTP/1.1 and Finder relies on it: a mount
    /// that opened a connection per request would spend its life in handshakes.
    var wantsKeepAlive: Bool {
        header("connection")?.lowercased().contains("close") != true
    }

    init(method: String, target: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.headers = headers
    }

    init(_ head: NIOHTTP1.HTTPRequestHead) {
        method = head.method.rawValue
        target = head.uri
        headers = [:]
        for (name, value) in head.headers {
            let name = name.lowercased()
            if let previous = headers[name] {
                headers[name] = previous + ", " + value
            } else {
                headers[name] = value
            }
        }
        if !head.isKeepAlive {
            headers["connection"] = "close"
        }
    }
}

/// One byte range from a `Range:` header, already clamped to the file.
struct ByteRange {
    var offset: Int64
    var count: Int64

    /// The single-range forms — `bytes=0-499`, `bytes=500-`, `bytes=-500`.
    ///
    /// Multiple ranges in one request are answered with the whole file instead
    /// of a `multipart/byteranges` body: nothing that mounts a volume asks for
    /// them, and the alternative is a MIME writer nobody would exercise.
    /// Returns nil when the header is absent or unusable, and
    /// `.unsatisfiable` when it is well-formed but off the end of the file,
    /// which is a 416 and not a 200.
    enum Parsed {
        /// No usable range: send the whole file, which is what the
        /// specification asks of a server that cannot honour the header.
        case absent
        case range(ByteRange)
        case unsatisfiable
    }

    static func parse(_ header: String?, fileSize: Int64) -> Parsed {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .absent }
        let spec = header.dropFirst("bytes=".count).trimmed
        guard !spec.contains(",") else { return .absent }
        let parts = spec.components(separatedBy: "-")
        guard parts.count == 2 else { return .absent }

        let first = parts[0].trimmed
        let last = parts[1].trimmed

        if first.isEmpty {
            // Suffix form: the last N bytes.
            guard let suffix = Int64(last), suffix > 0 else { return .absent }
            let count = min(suffix, fileSize)
            return count == 0 ? .unsatisfiable : .range(ByteRange(offset: fileSize - count, count: count))
        }
        guard let start = Int64(first), start >= 0 else { return .absent }
        guard start < fileSize else { return .unsatisfiable }
        let end = last.isEmpty ? fileSize - 1 : (Int64(last) ?? fileSize - 1)
        guard end >= start else { return .unsatisfiable }
        return .range(ByteRange(offset: start, count: min(end, fileSize - 1) - start + 1))
    }
}

/// RFC 1123 for `Last-Modified` and ISO 8601 for `creationdate`, both in the
/// fixed C locale — a formatter left on the device's locale writes month names
/// no client can read back.
enum HTTPDate {
    private static let http: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    static func rfc1123(_ seconds: Double) -> String {
        http.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func iso8601(_ seconds: Double) -> String {
        iso.string(from: Date(timeIntervalSince1970: seconds))
    }
}

extension StringProtocol {
    var trimmed: String {
        trimmingCharacters(in: .whitespaces)
    }
}
