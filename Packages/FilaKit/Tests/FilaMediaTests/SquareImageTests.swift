import CoreGraphics
@testable import FilaMedia
import Testing

@Suite("Square pictures")
struct SquareImageTests {
    /// Three bands along the long edge — red, green, blue — so which one the
    /// square landed on is the colour of its middle pixel.
    private static let bands: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]

    @Test("A portrait picture is cut at its anchor: a page's top, a photo's middle", arguments: [SquareImage.Anchor.top, .center])
    func portrait(anchor: SquareImage.Anchor) throws {
        let page = try banded(width: 40, height: 120, vertical: true)
        let square = try #require(SquareImage.make(page, anchor: anchor, maxSide: 512))
        #expect(square.width == 40)
        #expect(square.height == 40)
        #expect(try band(square, x: 20, y: 20) == (anchor == .top ? 0 : 1))
    }

    @Test("A landscape picture is cut from its middle, whatever the anchor", arguments: [SquareImage.Anchor.top, .center])
    func landscape(anchor: SquareImage.Anchor) throws {
        let photo = try banded(width: 120, height: 40, vertical: false)
        let square = try #require(SquareImage.make(photo, anchor: anchor, maxSide: 512))
        #expect(square.width == square.height)
        #expect(try band(square, x: 20, y: 20) == 1)
    }

    @Test("The square is no larger than asked")
    func bounded() throws {
        let square = try #require(SquareImage.make(banded(width: 300, height: 900, vertical: true), anchor: .top, maxSide: 64))
        #expect(square.width == 64)
        #expect(square.height == 64)
    }

    @Test("An icon is fitted whole into its square, never cut")
    func fitted() throws {
        let icon = try banded(width: 120, height: 40, vertical: false)
        let square = try #require(SquareImage.fit(icon, maxSide: 60))
        #expect(square.width == 60)
        #expect(square.height == 60)
        // All three bands survive, side by side across the middle row.
        #expect(try band(square, x: 5, y: 30) == 0)
        #expect(try band(square, x: 30, y: 30) == 1)
        #expect(try band(square, x: 55, y: 30) == 2)
        // Above and below the picture is transparent, not stretched picture.
        #expect(try alpha(square, x: 30, y: 2) == 0)
    }

    /// `vertical` stacks the bands top to bottom; otherwise left to right.
    private func banded(width: Int, height: Int, vertical: Bool) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for (index, band) in Self.bands.enumerated() {
            context.setFillColor(red: band.red, green: band.green, blue: band.blue, alpha: 1)
            // Core Graphics draws with its origin at the bottom left; the image
            // it makes has its first row at the top.
            let rect = vertical
                ? CGRect(x: 0, y: height - (index + 1) * height / 3, width: width, height: height / 3)
                : CGRect(x: index * width / 3, y: 0, width: width / 3, height: height)
            context.fill(rect)
        }
        return try #require(context.makeImage())
    }

    /// Which band pixel (x, y) of `image`, counted from the top, belongs to:
    /// its strongest channel, so a colour-space conversion cannot move it.
    private func band(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let channels = try pixel(image, x: x, y: y).prefix(3)
        return try #require(channels.firstIndex(of: channels.max()!))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        try pixel(image, x: x, y: y)[3]
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw the image so that pixel (x, y) lands on the context's only pixel.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }
}
