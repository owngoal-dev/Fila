import CoreGraphics

/// The square a picture is shown in, cut out of the picture itself.
///
/// Every cell draws a file's picture in a square slot, so a picture of any
/// other shape is either letterboxed there or cropped by the view. Cutting the
/// square here, once, at generation, is what lets every cell draw the same
/// thing the same way — and what lets the anchor depend on what the picture
/// is, which a view's `contentMode` cannot know.
public enum SquareImage {
    /// Where on the long edge the square is taken from.
    public enum Anchor: Sendable {
        /// The middle: a photo, a video frame, an icon.
        case center
        /// The top of a portrait page, where its title is. A landscape page is
        /// cut across its width, so it is taken from the middle like a photo.
        case top
    }

    /// The largest square of `image` at `anchor`, no larger than `maxSide`
    /// pixels. Redrawn rather than `cropping(to:)`, which would keep the whole
    /// source's pixels alive behind the square for as long as it is cached.
    public static func make(_ image: CGImage, anchor: Anchor, maxSide: Int) -> CGImage? {
        let source = min(image.width, image.height)
        let side = min(source, maxSide)
        guard source > 0, side > 0 else { return nil }
        let crop = CGRect(
            x: (image.width - source) / 2,
            y: anchor == .top ? 0 : (image.height - source) / 2,
            width: source,
            height: source
        )
        guard let square = image.cropping(to: crop),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
