import FilaProtocol
import Foundation
import UniformTypeIdentifiers
#if canImport(QuickLookThumbnailing)
    import ImageIO
    import QuickLookThumbnailing
#endif

/// `GET <file>?thumbnail=<px>` — a small PNG of the file for the browser page's
/// rows, rendered by QuickLook in this process.
///
/// This is the one place the server reads a shared file by path rather than
/// through a descriptor the backend opened: QuickLook takes a URL and nothing
/// else. It reads with the app's own rights, so a root-only file simply has no
/// thumbnail — the row keeps its icon — and the path has already passed the
/// same `isServed` and `details` checks as the download it stands in for.
// ponytail: no cache; QuickLook re-renders per request. Add a size-bounded on-disk cache keyed by inode/mtime if a camera roll on Wi-Fi feels slow.
extension WebDAVHandler {
    /// The requested edge in pixels, clamped to something a list row can use.
    static func thumbnailSide(in target: String) -> Int? {
        guard let mark = target.firstIndex(of: "?") else { return nil }
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.first == "thumbnail" else { continue }
            return min(max(Int(parts.count > 1 ? parts[1] : "") ?? 64, 16), 512)
        }
        return nil
    }

    func thumbnail(
        path: String,
        side: Int,
        node: FileNode,
        on http: HTTPConnection,
        includeBody: Bool
    ) async throws -> Int {
        guard let png = await Thumbnailer.png(for: path, side: side) else {
            try await respond(http, 404)
            return 404
        }
        try await http.write(head(200, headers: [
            ("Content-Type", "image/png"),
            ("Cache-Control", "private, max-age=3600"),
            ("ETag", "\"t\(node.inode)-\(side)-\(Int64(node.modified))\""),
        ], contentLength: png.count))
        if includeBody {
            try await http.write(png)
        }
        return 200
    }
}

enum Thumbnailer {
    /// A PNG no larger than `side` on either edge, or nil when QuickLook has no
    /// real rendering for the file — a generic document icon is not one, and
    /// the page draws its own.
    static func png(for path: String, side: Int) async -> Data? {
        #if canImport(QuickLookThumbnailing)
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: side, height: side),
                scale: 1,
                representationTypes: .thumbnail
            )
            guard
                let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            else {
                return nil
            }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else {
                return nil
            }
            CGImageDestinationAddImage(destination, representation.cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        #else
            return nil
        #endif
    }
}
