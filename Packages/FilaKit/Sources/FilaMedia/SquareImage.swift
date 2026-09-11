import CoreGraphics

/// The square a picture is shown in: cut out of a thumbnail (`make`), or
/// fitted around an icon (`fit`).
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
        guard let square = image.cropping(to: crop) else { return nil }
        return draw(square, side: side, in: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// All of `image`, fitted into a transparent square no larger than
    /// `maxSide`: an icon, whose every edge is part of the picture.
    public static func fit(_ image: CGImage, maxSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        let side = min(long, maxSide)
        guard long > 0, side > 0 else { return nil }
        let scale = CGFloat(side) / CGFloat(long)
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        let box = CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height)
        return draw(image, side: side, in: box)
    }

    private static func draw(_ image: CGImage, side: Int, in box: CGRect) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: box)
        return context.makeImage()
    }
}
