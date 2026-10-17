import Foundation

/// One `<D:response>` of a PROPFIND reply, reduced to what a listing needs.
struct WebDAVResource: Equatable, Sendable {
    /// The `href` as sent: an absolute path or an absolute URL, percent-encoded.
    var href: String
    var isCollection = false
    var contentLength: Int64?
    var lastModified: Date?
    var etag: String?

    /// The components of `href`'s path, each percent-decoded on its own, so
    /// an encoded `%2F` stays inside its component instead of splitting it.
    /// Nil when the href is not a path or a URL this module can read.
    var components: [String]? {
        let raw: String
        if let url = URL(string: href), url.scheme != nil {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            raw = parts.percentEncodedPath
        } else {
            raw = href
        }
        return Self.components(ofEncodedPath: raw)
    }

    /// `path`'s non-empty components, decoded one by one.
    static func components(ofEncodedPath path: String) -> [String]? {
        var decoded: [String] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let component = String(piece).removingPercentEncoding else { return nil }
            decoded.append(component)
        }
        return decoded
    }
}

/// Reads a `207 Multi-Status` body.
///
/// Elements are matched by namespace and local name, never by prefix: a
/// server may call the DAV namespace `D:`, `d:`, `lp1:` or nothing. Only a
/// propstat whose status is 2xx contributes properties, so a server that
/// lists `getcontentlength` under `404 Not Found` for a folder does not
/// give that folder a size.
enum WebDAVMultistatus {
    static let namespace = "DAV:"

    /// The PROPFIND body asking for exactly the properties read here.
    static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:"><D:prop>\
    <D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getetag/>\
    </D:prop></D:propfind>
    """.utf8)

    static func parse(_ data: Data) throws -> [WebDAVResource] {
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.sawMultistatus else {
            throw WebDAVError.invalidResponse
        }
        return reader.resources
    }

    /// `getlastmodified` is an RFC 1123 date. A server that sends an RFC 850
    /// or asctime one gets no date rather than a wrong one, and so does a
    /// zero time — Go's year 1, which Alist reports for its virtual folders,
    /// or the Unix epoch — which is a server saying it has none.
    static func date(_ text: String) -> Date? {
        guard let date = rfc1123.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              date.timeIntervalSince1970 > 0
        else { return nil }
        return date
    }

    private static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private final class Reader: NSObject, XMLParserDelegate {
        var resources: [WebDAVResource] = []
        var sawMultistatus = false

        private var current: WebDAVResource?
        /// The properties of the propstat being read, kept only if its
        /// status turns out to be a success.
        private var pending: WebDAVResource?
        private var propstatStatus: Int?
        private var text = ""
        private var stack: [String] = []

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName _: String?,
            attributes _: [String: String] = [:],
        ) {
            text = ""
            guard namespaceURI == WebDAVMultistatus.namespace else {
                stack.append("")
                return
            }
            stack.append(element)
            switch element {
            case "multistatus":
                sawMultistatus = true
            case "response":
                current = WebDAVResource(href: "")
            case "propstat":
                pending = current
                propstatStatus = nil
            case "collection" where stack.dropLast().last == "resourcetype":
                pending?.isCollection = true
            default:
                break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _: XMLParser,
            didEndElement element: String,
            namespaceURI: String?,
            qualifiedName _: String?,
        ) {
            defer {
                stack.removeLast()
                text = ""
            }
            guard namespaceURI == WebDAVMultistatus.namespace else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "href" where stack.dropLast().last == "response":
                current?.href = value
            case "status" where stack.dropLast().last == "propstat":
                propstatStatus = Self.statusCode(value)
            case "getcontentlength":
                pending?.contentLength = Int64(value)
            case "getlastmodified":
                pending?.lastModified = WebDAVMultistatus.date(value)
            case "getetag":
                pending?.etag = value.isEmpty ? nil : value
            case "propstat":
                if let pending, let status = propstatStatus, (200 ..< 300).contains(status) {
                    current = pending
                }
                pending = nil
            case "response":
                if let current, !current.href.isEmpty {
                    resources.append(current)
                }
                current = nil
            default:
                break
            }
        }

        /// The code in `HTTP/1.1 200 OK`.
        private static func statusCode(_ line: String) -> Int? {
            let parts = line.split(separator: " ")
            return parts.count >= 2 ? Int(parts[1]) : nil
        }
    }
}
