import Foundation
import FilaProtocol

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
    /// Nothing recognised it. The hex viewer is the floor, and every file has
    /// one — which is why this is a case and not a nil.
    case binary

    /// The first bytes of the file, and its name. `head` may be short; a file
    /// with fewer bytes than a signature simply does not match it.
    public static func detect(head: Data, name: String) -> FileFormat {
        if let signature = signatureMatch(head) { return signature }
        return extensionMatch(name) ?? (isProbablyText(head) ? .text : .binary)
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

    if hasPrefix([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) { return .propertyList } // "bplist"
    if hasPrefix([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66]) { return .sqlite } // "SQLite f"
    if hasPrefix([0x25, 0x50, 0x44, 0x46]) { return .pdf } // "%PDF"
    if hasPrefix([0x50, 0x4B, 0x03, 0x04]) || hasPrefix([0x50, 0x4B, 0x05, 0x06]) { return .archive } // zip
    if hasPrefix([0x1F, 0x8B]) { return .archive } // gzip
    if hasPrefix([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .archive } // xz, what most repos put data.tar in
    if hasPrefix([0x42, 0x5A, 0x68]) { return .archive } // bzip2
    if hasPrefix([0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E]) { return .archive } // "!<arch>", a .deb
    // The formats that arrived with libarchive and were never worth writing by
    // hand. All of them turn up on a jailbroken filesystem sooner or later.
    if hasPrefix([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .archive } // 7z
    if hasPrefix([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .archive } // "Rar!", rar and rar5
    if hasPrefix([0x28, 0xB5, 0x2F, 0xFD]) { return .archive } // zstd
    if hasPrefix([0x04, 0x22, 0x4D, 0x18]) { return .archive } // lz4
    if hasPrefix([0x78, 0x61, 0x72, 0x21]) { return .archive } // "xar!"
    if hasPrefix([0xFF, 0xD8, 0xFF]) { return .image } // jpeg
    if hasPrefix([0x89, 0x50, 0x4E, 0x47]) { return .image } // png
    if hasPrefix([0x47, 0x49, 0x46, 0x38]) { return .image } // gif
    // Mach-O, thin and fat, both byte orders.
    for magic in [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]] {
        if hasPrefix(magic.map(UInt8.init)) { return .machO }
    }
    if let text = String(data: head.prefix(64), encoding: .utf8), text.hasPrefix("<?xml") || text.hasPrefix("<!DOCTYPE plist") {
        return .propertyList
    }
    // tar's only signature is 257 bytes in, which is why `detectionByteCount`
    // is 512 and not something smaller: a `data.tar` extracted out of a deb has
    // no extension and nothing else says what it is.
    if head.count >= 262, Array(head[257 ..< 262]) == [0x75, 0x73, 0x74, 0x61, 0x72] { return .archive } // "ustar"
    return nil
}

private func extensionMatch(_ name: String) -> FileFormat? {
    switch (name as NSString).pathExtension.lowercased() {
    case "plist", "strings", "entitlements": .propertyList
    case "zip", "ipa", "deb", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "7z",
         "rar", "zst", "lz4", "lzma", "xar", "cpio", "iso", "cab", "lha", "lzh": .archive
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "icns": .image
    case "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac": .audio
    case "mp4", "mov", "m4v", "mkv", "avi": .video
    case "pdf": .pdf
    case "db", "sqlite", "sqlite3": .sqlite
    case "dylib", "so", "a", "framework": .machO
    case "txt", "md", "json", "log", "sh", "conf", "cfg", "ini", "yml", "yaml", "c", "h", "m", "mm", "swift", "js", "py", "rb", "html", "css", "xml", "pl", "list": .text
    default: nil
    }
}

/// Valid UTF-8 with no NUL byte. The NUL test is what separates a binary that
/// happens to decode from a file someone wants to edit.
private func isProbablyText(_ head: Data) -> Bool {
    guard !head.isEmpty else { return true }
    guard !head.contains(0) else { return false }
    return String(data: head, encoding: .utf8) != nil
}
