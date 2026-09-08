import CoreGraphics
import FilaFormats
import Foundation
import ImageIO

/// A first-frame preview whose decoded raster has a fixed pixel ceiling.
/// File-size checks alone cannot bound a compressed image's decoded allocation.
public enum ImagePreview {
    public static func make(data: Data) -> CGImage? {
        guard data.count <= PreviewLimits.fileByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        guard hasSupportedDimensions(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: PreviewLimits.imagePixelSize,
        ] as CFDictionary)
    }

    static func hasSupportedDimensions(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 32_768, height <= 32_768 else { return false }
        return width <= 64_000_000 / height
    }
}
