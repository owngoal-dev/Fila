import CoreGraphics
import Foundation
import ImageIO

/// Thumbnails drawn straight off a descriptor, without the file ever being
/// resident.
///
/// ImageIO and Core Graphics both take a `CGDataProvider`, and a provider can be
/// a pair of callbacks rather than a block of memory — so the "read the file,
/// then decode it" step that every naive thumbnail does never happens here. A
/// provider avoids loading a second complete copy. Input and raster budgets
/// still apply because a decoder may allocate intermediate buffers.
enum DescriptorImage {
    /// A thumbnail no larger than `maxPixelSize` on its long edge.
    ///
    /// The thumbnail bounds the returned raster. Source dimensions are checked
    /// separately because codec intermediate allocations are format-dependent.
    static func thumbnail(descriptor: Int32, byteCount: Int64, maxPixelSize: Int) -> CGImage? {
        let reads = ReadLog()
        guard let provider = provider(descriptor: descriptor, byteCount: byteCount, reads: reads),
              let source = CGImageSourceCreateWithDataProvider(
                  provider,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else { return nil }
        guard ImagePreview.hasSupportedDimensions(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        return reads.failed ? nil : image
    }

    /// The first page of a PDF, fitted into `maxPixelSize`. White behind it
    /// rather than transparent, because a PDF page is ink on paper and ink on
    /// nothing is invisible in dark mode.
    static func firstPage(descriptor: Int32, byteCount: Int64, maxPixelSize: Int) -> CGImage? {
        let reads = ReadLog()
        guard let provider = provider(descriptor: descriptor, byteCount: byteCount, reads: reads),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else { return nil }

        // `/Rotate 90` is ordinary in anything scanned, and a hand-rolled scale
        // and translate ignores it — the page comes out on its side and fitted
        // to the wrong edge. `getDrawingTransform` is the one call that knows
        // about the rotation, so the box is measured through it too.
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        let rotation = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = CGFloat(maxPixelSize) / max(rotation.width, rotation.height)
        let width = max(1, Int((rotation.width * scale).rounded()))
        let height = max(1, Int((rotation.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(
            .cropBox,
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        return reads.failed ? nil : context.makeImage()
    }

    /// A provider that answers by `pread` on its own `dup(2)` of the descriptor.
    ///
    /// It duplicates rather than borrows because Core Graphics decides when the
    /// provider dies, and a provider outliving the caller's `close(2)` would be
    /// reading whatever file inherited the number — a wrong picture rather than
    /// a failure, which is the worse of the two.
    private static func provider(descriptor: Int32, byteCount: Int64, reads: ReadLog) -> CGDataProvider? {
        let copy = dup(descriptor)
        guard copy >= 0, byteCount > 0 else {
            if copy >= 0 {
                close(copy)
            }
            return nil
        }
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let file = Unmanaged<DescriptorBox>.fromOpaque(info).takeUnretainedValue()
                while true {
                    let got = pread(file.descriptor, buffer, count, off_t(position))
                    if got < 0 {
                        if errno == EINTR {
                            continue
                        }
                        // A direct provider has no way to say "error" — zero
                        // reads to Core Graphics as end of data, and the caller
                        // gets a silently truncated picture. So the failure is
                        // recorded here and the caller throws the result away.
                        file.reads.recordFailure()
                        return 0
                    }
                    return got
                }
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<DescriptorBox>.fromOpaque(info).release()
            }
        )
        let box = Unmanaged.passRetained(DescriptorBox(descriptor: copy, reads: reads)).toOpaque()
        guard let provider = CGDataProvider(directInfo: box, size: off_t(byteCount), callbacks: &callbacks) else {
            Unmanaged<DescriptorBox>.fromOpaque(box).release()
            return nil
        }
        return provider
    }
}

/// A descriptor owned by whatever holds the box, so Core Graphics releasing the
/// provider is what closes it.
private final class DescriptorBox {
    let descriptor: Int32
    let reads: ReadLog

    init(descriptor: Int32, reads: ReadLog) {
        self.descriptor = descriptor
        self.reads = reads
    }

    deinit { close(descriptor) }
}

/// Codecs may read a provider from several worker threads.
private final class ReadLog {
    private let lock = NSLock()
    private var storedFailure = false

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        storedFailure = true
    }
}
