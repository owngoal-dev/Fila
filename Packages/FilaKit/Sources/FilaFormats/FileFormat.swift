import Foundation
import UniformTypeIdentifiers

/// What a file looks like from the outside, so the app can pick a viewer.
///
/// Detection is by content first and extension second, because on a jailbroken
/// filesystem half the interesting files have no extension at all — a Mach-O
/// binary in `/usr/libexec`, a binary plist named `com.apple.something`, a
/// launchd job with a `.plist` that is XML this week and binary the next.
public enum FileFormat: Sendable, Hashable, CaseIterable {
    case propertyList
    case machO
    case archive
    case image
    case audio
    case video
    case pdf
    case sqlite
    case text
    /// Binary content without a dedicated viewer.
    case binary

    /// Content signatures take precedence, followed by known extensions and
    /// system MIME types. Otherwise prefer text unless binary controls say
    /// otherwise. `head` may be short, including empty for list icons.
    public static func detect(head: Data, name: String) -> FileFormat {
        let head = Data(head.prefix(detectionByteCount))
        if let signature = signatureMatch(head) {
            return signature
        }
        return extensionMatch(name) ?? (hasBinaryControls(head) ? .binary : .text)
    }

    /// What the name alone says: nil for a missing or unknown extension,
    /// where `detect` with an empty head guesses text.
    public static func detect(name: String) -> FileFormat? {
        extensionMatch(name)
    }

    /// How many bytes `detect` wants. Reading more is waste; reading fewer
    /// misses the longest signature.
    public static let detectionByteCount = 512
}

private func signatureMatch(_ head: Data) -> FileFormat? {
    func hasPrefix(_ bytes: [UInt8]) -> Bool {
        guard head.count >= bytes.count else { return false }
        return Array(head.prefix(bytes.count)) == bytes
    }

    if hasPrefix([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) {
        return .propertyList
    } // "bplist"
    if hasPrefix([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66]) {
        return .sqlite
    } // "SQLite f"
    if hasPrefix([0x25, 0x50, 0x44, 0x46]) {
        return .pdf
    } // "%PDF"
    if hasPrefix([0x50, 0x4B, 0x03, 0x04]) || hasPrefix([0x50, 0x4B, 0x05, 0x06]) {
        return .archive
    } // zip
    if hasPrefix([0x1F, 0x8B]) {
        return .archive
    } // gzip
    if hasPrefix([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
        return .archive
    } // xz, what most repos put data.tar in
    if hasPrefix([0x42, 0x5A, 0x68]) {
        return .archive
    } // bzip2
    if hasPrefix([0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E]) {
        return .archive
    } // "!<arch>", a .deb
    // The formats that arrived with libarchive and were never worth writing by
    // hand. All of them turn up on a jailbroken filesystem sooner or later.
    if hasPrefix([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
        return .archive
    } // 7z
    if hasPrefix([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) {
        return .archive
    } // "Rar!", rar and rar5
    if hasPrefix([0x28, 0xB5, 0x2F, 0xFD]) {
        return .archive
    } // zstd
    if hasPrefix([0x04, 0x22, 0x4D, 0x18]) {
        return .archive
    } // lz4
    if hasPrefix([0x78, 0x61, 0x72, 0x21]) {
        return .archive
    } // "xar!"
    if hasPrefix([0xFF, 0xD8, 0xFF]) {
        return .image
    } // jpeg
    if hasPrefix([0x89, 0x50, 0x4E, 0x47]) {
        return .image
    } // png
    if hasPrefix([0x47, 0x49, 0x46, 0x38]) {
        return .image
    } // gif
    // Mach-O, thin and fat, both byte orders.
    for magic in [
        [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE],
        [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
        [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
        [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA],
    ] {
        if hasPrefix(magic.map(UInt8.init)) {
            return .machO
        }
    }
    if isXMLPropertyList(head) {
        return .propertyList
    }
    // tar's only signature is 257 bytes in, which is why `detectionByteCount`
    // is 512 and not something smaller: a `data.tar` extracted out of a deb has
    // no extension and nothing else says what it is.
    if head.count >= 262, Array(head[257 ..< 262]) == [0x75, 0x73, 0x74, 0x61, 0x72] {
        return .archive
    } // "ustar"
    return nil
}

private func extensionMatch(_ name: String) -> FileFormat? {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "plist", "strings", "entitlements": return .propertyList
    case "zip", "ipa", "deb", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "7z",
         "rar", "zst", "lz4", "lzma", "xar", "cpio", "iso", "cab", "lha", "lzh", "a": return .archive
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "icns": return .image
    case "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac": return .audio
    case "mp4", "mov", "m4v", "mkv", "avi": return .video
    case "pdf": return .pdf
    case "db", "sqlite", "sqlite3": return .sqlite
    case "txt", "md", "json", "log", "sh", "conf", "cfg", "ini", "yml", "yaml", "c", "h", "m",
         "mm", "swift", "js", "py", "rb", "html", "css", "xml", "caml", "pl", "list": return .text
    default: break
    }

    // System declarations fill gaps in the viewer table. A dynamic UTI or a
    // generic data type says nothing about whether the bytes are text.
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
    if type.conforms(to: .image) {
        return .image
    }
    if type.conforms(to: .audio) {
        return .audio
    }
    if type.conforms(to: .movie) {
        return .video
    }
    if type.conforms(to: .archive) {
        return .archive
    }
    if type.conforms(to: .text) {
        return .text
    }
    guard let mime = type.preferredMIMEType, mime != "application/octet-stream" else { return nil }
    if mime.hasPrefix("text/") || mime.hasSuffix("+xml") || mime.hasSuffix("+json")
        || mime == "application/xml" || mime == "application/json"
    {
        return .text
    }
    return .binary
}

/// Like file(1), distinguish printable bytes and common text controls from
/// binary controls. A cut UTF-8 sequence or a legacy 8-bit encoding alone is
/// not evidence of binary content; the text viewer can preserve those bytes.
private func hasBinaryControls(_ head: Data) -> Bool {
    head.contains { byte in
        switch byte {
        case 0x07 ... 0x0D, 0x1A, 0x1B: false
        case 0x00 ... 0x1F, 0x7F: true
        default: false
        }
    }
}

/// An XML declaration identifies XML, not a plist. Inspect only the root
/// element in the bounded detection window; CAML and other XML remain text.
private func isXMLPropertyList(_ head: Data) -> Bool {
    guard !head.isEmpty else { return false }
    let root = PropertyListRoot()
    let parser = XMLParser(data: head)
    parser.delegate = root
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.parse()
    return root.isPropertyList
}

private final class PropertyListRoot: NSObject, XMLParserDelegate {
    var isPropertyList = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String]
    ) {
        isPropertyList = elementName == "plist"
        parser.abortParsing()
    }
}
