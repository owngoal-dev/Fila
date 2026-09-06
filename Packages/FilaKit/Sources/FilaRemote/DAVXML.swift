import FilaProtocol
import Foundation

/// Serializes the server's directory properties without parsing request XML.
/// PROPFIND currently returns the available property set. Locking is unsupported.
enum DAVXML {
    static let multistatusOpen = """
    <?xml version="1.0" encoding="utf-8"?>\r
    <D:multistatus xmlns:D="DAV:">\r

    """

    static let multistatusClose = "</D:multistatus>\r\n"

    /// One `<D:response>` for a node, with everything Finder reads to draw a row
    /// and everything it checks before it will write.
    static func response(href: String, node: FileNode, isCollection: Bool) -> String {
        let resourceType = isCollection ? "<D:collection/>" : ""
        // A weak validator built from what `lstat` already told us. Finder uses
        // it for its own caching; there is nothing here worth a content hash,
        // and computing one would mean reading every served file twice.
        let tag = entityTag(inode: node.inode, size: node.size, modified: node.modified)
        var properties = """
        <D:displayname>\(escape(node.name))</D:displayname>\
        <D:resourcetype>\(resourceType)</D:resourcetype>\
        <D:getlastmodified>\(HTTPDate.rfc1123(node.modified))</D:getlastmodified>\
        <D:creationdate>\(HTTPDate.iso8601(node.created))</D:creationdate>\
        <D:getetag>\(tag)</D:getetag>\
        <D:supportedlock/>\
        <D:lockdiscovery/>
        """
        if !isCollection {
            properties += """
            <D:getcontentlength>\(max(0, node.size))</D:getcontentlength>\
            <D:getcontenttype>application/octet-stream</D:getcontenttype>
            """
        }
        return """
        <D:response><D:href>\(escape(href))</D:href><D:propstat><D:prop>\(properties)</D:prop>\
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\r\n
        """
    }

    /// Metadata is useful for caching but cannot prove byte equality when
    /// another process edits a file in place and preserves its timestamps.
    static func entityTag(inode: UInt64, size: Int64, modified: Double) -> String {
        "W/\"\(inode)-\(size)-\(modified.bitPattern)\""
    }

    /// A `PROPFIND` with `Depth: infinity` is refused with this, which is what
    /// tells a client to ask again with `Depth: 1` instead of giving up.
    static let finiteDepthError = """
    <?xml version="1.0" encoding="utf-8"?>\r
    <D:error xmlns:D="DAV:"><D:propfind-finite-depth/></D:error>\r\n
    """

    /// The five predefined entities, plus the control characters XML 1.0 has no
    /// spelling for at all.
    ///
    /// Both halves are about the same failure. A file may legally be named
    /// `<script>` or `A & B`, and a POSIX name may legally contain a byte like
    /// `0x01` — but a `multistatus` carrying any of them raw is not well-formed,
    /// and a client that cannot parse the document shows *nothing*, so one
    /// strange name would hide every file beside it. Tab, newline and carriage
    /// return are the three controls XML does allow, and they are kept.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.append(character)
            default:
                if let scalar = character.unicodeScalars.first,
                   character.unicodeScalars.count == 1, scalar.value < 0x20 {
                    // No numeric reference either: XML 1.0 cannot represent
                    // these even escaped, so the only honest answer is to drop
                    // them from the name the client is shown.
                    continue
                }
                out.append(character)
            }
        }
        return out
    }
}
