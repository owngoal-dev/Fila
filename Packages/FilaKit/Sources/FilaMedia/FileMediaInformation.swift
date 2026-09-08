import AVFoundation
import FilaFormats
import Foundation
import ImageIO

/// Metadata only: no image raster, playback, or temporary copy.
public struct FileMediaInformation: Sendable {
    public private(set) var width: Double?
    public private(set) var height: Double?
    public private(set) var duration: Double?
    public private(set) var frameRate: Double?

    /// Borrows the descriptor; providers and media loaders own their duplicates.
    public static func read(descriptor: Int32, name: String) async throws -> Self {
        try Task.checkCancellation()
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        let format = FileFormat.detect(head: Data(), name: name)
        var result = Self()
        if format == .image {
            guard let provider = DescriptorImage.provider(descriptor: descriptor, byteCount: Int64(status.st_size)),
                  let source = CGImageSourceCreateWithDataProvider(
                      provider, [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return result }
            let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
            let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
            let orientation = (values[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            result.width = (5 ... 8).contains(orientation) ? height : width
            result.height = (5 ... 8).contains(orientation) ? width : height
        } else if format == .audio || format == .video {
            let copy = dup(descriptor)
            guard copy >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let media = DescriptorAsset(descriptor: copy, name: name)
            return try await withTaskCancellationHandler {
                var result = Self()
                let duration = try await media.asset.load(.duration).seconds
                if duration.isFinite, duration >= 0 {
                    result.duration = duration
                }
                if let track = try await media.asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let display = CGRect(origin: .zero, size: size).applying(transform).size
                    if display.width.isFinite, display.height.isFinite {
                        result.width = abs(display.width)
                        result.height = abs(display.height)
                    }
                    let rate = try await track.load(.nominalFrameRate)
                    if rate.isFinite, rate > 0 {
                        result.frameRate = Double(rate)
                    }
                }
                try Task.checkCancellation()
                withExtendedLifetime(media) {}
                return result
            } onCancel: {
                media.asset.cancelLoading()
            }
        }
        return result
    }
}
