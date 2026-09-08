import Foundation

/// The translation between a request target and a path on the device, and the
/// only place in this package allowed to make one.
///
/// A URL path is written by whoever reached the port. The rule here is that it
/// is taken apart *before* it is decoded, never after: split on `/` first, then
/// percent-decode each component on its own. A server that decodes the whole
/// string and splits afterwards turns `%2e%2e%2f` into `../` and hands the
/// caller the parent directory; splitting first means an escaped separator can
/// only ever become a character inside one name, which is also what it means.
///
/// `..` is then refused outright rather than resolved. Resolving is defensible
/// and `FilaGuard.normalize` does it — but nothing a WebDAV client legitimately
/// sends contains one, so refusing costs no functionality and leaves no lexical
/// edge case to be clever about.
public enum RemotePath {
    /// The filesystem path a request target names, or nil when it names nothing
    /// that may be served.
    ///
    /// `target` may be an origin-form path (`/var/mobile/x`) or the absolute
    /// form macOS puts in a `Destination:` header
    /// (`http://phone.local:8080/var/mobile/x`). Both end up here.
    public static func filesystemPath(for target: String, root: String) -> String? {
        guard let components = components(of: target) else { return nil }
        let base = root == "/" ? "" : root
        return components.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + components.joined(separator: "/")
    }

    /// The path components of a request target, decoded and checked, or nil if
    /// any of them is one this server refuses to look at.
    static func components(of target: String) -> [String]? {
        var text = target

        // Absolute form. Everything up to the third slash is scheme and
        // authority; an authority with no path at all is the collection root.
        if let range = text.range(of: "://") {
            let rest = text[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return [] }
            text = String(rest[slash...])
        }
        // Query and fragment are not part of the name of a file.
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        guard text.hasPrefix("/") else { return nil }

        var result: [String] = []
        for raw in text.split(separator: "/", omittingEmptySubsequences: true) {
            guard let name = String(raw).removingPercentEncoding else { return nil }
            // `.` and `..` never name a file, `/` cannot be in one, and a NUL
            // truncates every path the C library will later be handed.
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0") else { return nil }
            result.append(name)
        }
        return result
    }

    /// The `href` a `PROPFIND` reports for a path, percent-encoded.
    ///
    /// A collection's href ends in a slash. Finder tolerates it missing; other
    /// clients do not, and the specification is unambiguous.
    public static func href(for path: String, root: String, isCollection: Bool) -> String {
        let base = root == "/" ? "" : root
        var remainder = path
        if !base.isEmpty, remainder.hasPrefix(base) {
            remainder.removeFirst(base.count)
        }
        let encoded = remainder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(escape)
            .joined(separator: "/")
        let href = "/" + encoded
        return isCollection && href != "/" ? href + "/" : href
    }

    /// One path component, percent-encoded for a URL path.
    ///
    /// Spelled as an allow-list rather than `addingPercentEncoding(withAllowed:
    /// .urlPathAllowed)`, which permits `/` — the one character that must not
    /// survive here, because a file really can be named with one on some
    /// filesystems and it would silently become a directory boundary.
    static func escape(_ component: some StringProtocol) -> String {
        var out = ""
        for byte in Array(component.utf8) {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// `directory + "/" + name`, without the double slash at the volume root.
    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    public static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
