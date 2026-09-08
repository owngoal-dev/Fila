import CoreGraphics
@testable import FilaMedia
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

/// Real files and real descriptors, like every other suite here — the point of
/// these generators is that they read through a descriptor, and a fake in front
/// of them would prove nothing about the only thing that can go wrong.
@Suite("Thumbnails")
struct ThumbnailTests {
    @Test("Background thumbnails do not promote a named image into PDF decoding")
    func misleadingPDFName() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("wallpaper.png")
            try writePDF(to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let image = await service.thumbnail(path: url.path, modified: 1, byteCount: size,
                                                open: { try openForReading(url) })
            #expect(image == nil)
            let pdf = await service.thumbnail(path: directory.appendingPathComponent("wallpaper.pdf").path,
                                              modified: 1, byteCount: size,
                                              open: { try openForReading(url) })
            #expect(pdf != nil)
        }
    }

    @Test("Full image previews downsample an ordinary large image before display")
    func previewPixelLimit() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("wide-preview.png")
            try writePNG(width: 8192, height: 64, to: url)
            let image = try #require(ImagePreview.make(data: Data(contentsOf: url)))
            #expect(image.width == 4096)
            #expect(image.height == 32)
        }
    }

    @Test("An image thumbnail comes back inside the pixel bound")
    func imageThumbnail() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("wide.png")
            try writePNG(width: 900, height: 300, to: url)
            try withDescriptor(reading: url) { descriptor in
                let size = try byteCount(of: url)
                let image = DescriptorImage.thumbnail(descriptor: descriptor, byteCount: size, maxPixelSize: 64)
                let thumbnail = try #require(image)
                #expect(max(thumbnail.width, thumbnail.height) == 64)
                // Aspect kept: 900x300 is 3:1, so the short edge lands on 21.
                #expect(thumbnail.height < thumbnail.width)
            }
        }
    }

    @Test("The provider outlives the caller's descriptor, because it dups")
    func providerOwnsItsDescriptor() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("closed.png")
            try writePNG(width: 200, height: 200, to: url)
            let size = try byteCount(of: url)
            let descriptor = try openForReading(url)
            let image = DescriptorImage.thumbnail(descriptor: descriptor, byteCount: size, maxPixelSize: 32)
            // Closing here is what a caller does the moment generation returns;
            // a borrowed descriptor would make the next read a wrong picture.
            close(descriptor)
            #expect(image != nil)
        }
    }

    @Test("A PDF's first page renders, on white rather than on nothing")
    func pdfFirstPage() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("one.pdf")
            try writePDF(to: url)
            try withDescriptor(reading: url) { descriptor in
                let size = try byteCount(of: url)
                let page = DescriptorImage.firstPage(descriptor: descriptor, byteCount: size, maxPixelSize: 48)
                let image = try #require(page)
                #expect(max(image.width, image.height) == 48)
            }
        }
    }

    @Test("Something that is not a picture fails to nil rather than to an error")
    func unsupportedIsSilent() throws {
        try withScratch { directory in
            let url = directory.appendingPathComponent("notes.txt")
            try Data("just words".utf8).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                #expect(DescriptorImage.thumbnail(descriptor: descriptor, byteCount: 10, maxPixelSize: 64) == nil)
            }
        }
    }

    @Test("The service caches on path, time and size together")
    func cacheKey() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("cached.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()

            let opens = Counter()
            func generate(modified: Double) async -> CGImage? {
                await service.thumbnail(
                    path: url.path,
                    modified: modified,
                    byteCount: size,
                    maxPixelSize: 32,
                    open: { await opens.bump(); return try openForReading(url) }
                )
            }

            #expect(await generate(modified: 1) != nil)
            #expect(await generate(modified: 1) != nil)
            #expect(await opens.value == 1, "the second call must not reach the file at all")

            // The same file edited in place: a new time, so a new picture.
            #expect(await generate(modified: 2) != nil)
            #expect(await opens.value == 2)
        }
    }

    @Test("A rotated page is drawn upright, not on its side")
    func rotatedPDF() throws {
        try withScratch { directory in
            let upright = directory.appendingPathComponent("upright.pdf")
            let sideways = directory.appendingPathComponent("sideways.pdf")
            try writePDF(to: upright, rotate: 0)
            try writePDF(to: sideways, rotate: 90)

            func render(_ url: URL) throws -> (width: Int, height: Int) {
                try withDescriptor(reading: url) { descriptor in
                    let image = try #require(try DescriptorImage.firstPage(
                        descriptor: descriptor,
                        byteCount: byteCount(of: url),
                        maxPixelSize: 64
                    ))
                    return (image.width, image.height)
                }
            }

            // The page is 200x100. Upright that is landscape; rotated a quarter
            // turn it is portrait, and a thumbnail that ignored `/Rotate` would
            // come back landscape both times.
            let flat = try render(upright)
            #expect(flat.width > flat.height)
            let turned = try render(sideways)
            #expect(turned.height > turned.width)
        }
    }

    @Test("A daemon that has not started yet is not remembered as a failure")
    func openFailureIsNotCached() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("later.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let attempts = Counter()

            struct NotUpYet: Error {}
            // `filad` is on-demand: the first look-up after a respring misses,
            // and the file is perfectly thumbnail-able a moment later.
            let refused = await service.thumbnail(
                path: url.path,
                modified: 1,
                byteCount: size,
                open: { await attempts.bump(); throw NotUpYet() }
            )
            #expect(refused == nil)

            let second = await service.thumbnail(
                path: url.path,
                modified: 1,
                byteCount: size,
                open: { await attempts.bump(); return try openForReading(url) }
            )
            #expect(second != nil, "the refusal must not have been cached")
            #expect(await attempts.value == 2)
        }
    }

    @Test("A file that produces nothing is not re-opened on every pass")
    func failuresAreRemembered() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("notes.txt")
            try Data("just words".utf8).write(to: url)
            let service = ThumbnailService()
            let opens = Counter()
            for _ in 0 ..< 3 {
                let image = await service.thumbnail(
                    path: url.path,
                    modified: 1,
                    byteCount: 10,
                    open: { await opens.bump(); return try openForReading(url) }
                )
                #expect(image == nil)
            }
            #expect(await opens.value == 1)
        }
    }

    @Test("A cancelled row opens nothing")
    func cancellationOpensNothing() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("scrolled.png")
            try writePNG(width: 120, height: 120, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let opens = Counter()

            let task = Task {
                await service.thumbnail(
                    path: url.path,
                    modified: 1,
                    byteCount: size,
                    open: { await opens.bump(); return try openForReading(url) }
                )
            }
            task.cancel()
            #expect(await task.value == nil)
            #expect(await opens.value == 0)
        }
    }

    @Test("Never more than the bound in flight at once")
    func concurrencyIsBounded() async throws {
        try await withScratchAsync { directory in
            let url = directory.appendingPathComponent("crowd.png")
            try writePNG(width: 400, height: 400, to: url)
            let size = try byteCount(of: url)
            let service = ThumbnailService()
            let peak = Peak()

            await withTaskGroup(of: Void.self) { group in
                for index in 0 ..< 40 {
                    group.addTask {
                        _ = await service.thumbnail(
                            path: url.path,
                            // A distinct key per task, or the cache answers all
                            // but one and nothing is ever in flight.
                            modified: Double(index),
                            byteCount: size,
                            maxPixelSize: 64,
                            open: {
                                await peak.observe(service.activeCount)
                                return try openForReading(url)
                            }
                        )
                    }
                }
            }
            #expect(await peak.highest <= ThumbnailService.concurrencyLimit)
            #expect(await peak.highest > 0)
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private actor Peak {
    private(set) var highest = 0

    func observe(_ count: Int) {
        highest = max(highest, count)
    }
}

// MARK: - Fixtures

private func byteCount(of url: URL) throws -> Int64 {
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    return size?.int64Value ?? 0
}

private func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailed() }
}

struct FixtureFailed: Error {}

private func writePDF(to url: URL, rotate: Int = 0) throws {
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 10, y: 10, width: 60, height: 40))
    context.endPDFPage()
    context.closePDF()

    // Core Graphics has no page-dictionary key for `/Rotate`, so the rotation is
    // stamped on afterwards — which is also how a scanner produces one.
    guard rotate != 0 else { return }
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { throw FixtureFailed() }
    page.rotation = rotate
    guard document.write(to: url) else { throw FixtureFailed() }
}
