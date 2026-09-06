import FilaProtocol
import ImageIO
import UIKit

/// Thumbnails for the grid.
///
/// Images only, and only small ones: a thumbnail is a convenience, and reading a
/// 200 MB TIFF through a descriptor to draw a 60-point square is not one. Video
/// and PDF want a file URL that `mobile` cannot open, so they keep their icon.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    static let sourceByteCeiling = 8 * 1_024 * 1_024
    /// Read by `downsample`, which runs off the main actor.
    nonisolated static let pixelSize = 160

    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 400 }

    func thumbnail(for path: String, node: FileNode, session: FileSession) async -> UIImage? {
        guard node.size > 0, node.size <= Self.sourceByteCeiling else { return nil }
        // Keyed by modification time as well as path, so editing a file in place
        // does not leave the old picture on screen.
        let key = "\(path)@\(node.modified)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? await session.read(path, limit: Self.sourceByteCeiling) else { return nil }
        guard let image = await Task.detached(priority: .utility, operation: {
            Self.downsample(data)
        }).value else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private nonisolated static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
