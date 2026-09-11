import CoreGraphics
import FilaFormats
import Foundation
#if canImport(QuickLookThumbnailing)
    import QuickLookThumbnailing
#endif

/// Thumbnails for a file list, generated in this process from a descriptor the
/// daemon opened.
///
/// **No helper process, and nothing is spawned.** The obvious shape for this is
/// a uid-501 helper reading QuickLook previews, and the isolation it would buy
/// is real — but it buys nothing *here*, because none of these three generators
/// needs a path or a privilege:
///
/// - images go through ImageIO over a `CGDataProvider` on the descriptor,
/// - PDFs through Core Graphics over the same provider,
/// - video through `AVAssetImageGenerator` over the same resource loader that
///   plays the file.
///
/// The app already holds the bytes; drawing a 160-point square out of them is
/// arithmetic, not authority.
///
/// `QLThumbnailGenerator` draws what those three cannot — a text page, an
/// office document, a font — but it only takes a file URL and reads it in its
/// own process, as this app. So it is asked only for a path this process can
/// read itself (`quickLookThumbnail`), never for a file the daemon opened on
/// its behalf: copying every root-only file the user scrolls past into the
/// container first would be the wrong way round. Measured on the device, a
/// path the app cannot read is not a failure there but a blank page.
///
/// Everything here fails to `nil`. A thumbnail is a convenience; the caller
/// already has a file-type icon, and a picture that could not be made is not
/// something to tell the user about.
public actor ThumbnailService {
    public static let shared = ThumbnailService()

    /// How many thumbnails are generated at once.
    ///
    /// The bound is what makes this safe on a fast scroll: without it, a flick
    /// through a folder of a thousand videos starts a thousand descriptors and
    /// a thousand decoders. Four is enough to keep a screenful ahead of the user
    /// and small enough that the descriptors are never the reason the app dies.
    static let concurrencyLimit = 4
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Keyed on path, modification time and size together. Path alone leaves the
    /// old picture on screen after an edit; time alone collides across a copy
    /// that preserved it. `NSCache` because it is the one cache on the platform
    /// that gives memory back under pressure, which is the pressure a file list
    /// creates.
    private let images = NSCache<NSString, CGImage>()
    /// The files that produced nothing, so a folder of unsupported video does
    /// not re-open and re-decode every one of them on every scroll pass.
    private let failures = NSCache<NSString, NSNull>()
    private let executableIcons = NSCache<NSString, NSNumber>()

    /// A fresh service, with its own cache. The app wants `shared`; a second one
    /// exists so a test can start from an empty cache.
    public init() {
        // A 160-point thumbnail is about 100 KB, so a full cache is a few tens
        // of megabytes — and `NSCache` gives it all back under pressure.
        images.countLimit = 256
        images.totalCostLimit = 32 * 1024 * 1024
        failures.countLimit = 256
        executableIcons.countLimit = 512
    }

    /// Identify Mach-O artwork without decoding content or trusting execute bits.
    /// Uses the thumbnail queue so scrolling cannot exhaust descriptors.
    public func isMachO(path: String, modified: Double, byteCount: Int64, cacheResult: Bool = true,
                        open: @escaping @Sendable () async throws -> Int32) async -> Bool
    {
        guard byteCount >= 4, !Task.isCancelled else { return false }
        let key = "\(path)@\(modified.bitPattern)@\(byteCount)" as NSString
        if cacheResult, let hit = executableIcons.object(forKey: key) {
            return hit.boolValue
        }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return false }
        if cacheResult, let hit = executableIcons.object(forKey: key) {
            return hit.boolValue
        }
        guard let descriptor = try? await open(), descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return false }
        var head = Data(count: 4)
        let count = head.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 4, 0) }
        guard count == 4 else { return false }
        let result = FileFormat.detect(head: head, name: "") == .machO
        if cacheResult {
            executableIcons.setObject(NSNumber(value: result), forKey: key)
        }
        return result
    }

    /// A thumbnail for the file at `path`, or nil — which means "draw the icon"
    /// and never "tell the user something failed".
    ///
    /// `open` is called at most once, only when the answer is not already
    /// cached, and only once a generation slot is free; it must return a
    /// descriptor this service may close. Cancel the surrounding `Task` when the
    /// row scrolls away: a cancelled call does no work and opens nothing.
    ///
    /// `modified` and `byteCount` come from the `lstat` the listing already did,
    /// so a cache hit costs no daemon round trip at all. They key the cache and
    /// nothing else — the size the generators are given is `fstat`ed off the
    /// descriptor, which is the only size that is true at the moment it is read.
    public func thumbnail(
        path: String,
        modified: Double,
        byteCount: Int64,
        maxPixelSize: Int = 160,
        open: @escaping @Sendable () async throws -> Int32
    ) async -> CGImage? {
        guard byteCount > 0, maxPixelSize > 0, maxPixelSize <= 512 else { return nil }
        let key = "\(path)@\(modified.bitPattern)@\(byteCount)@\(maxPixelSize)" as NSString
        return await generate(key) {
            // A failed open is never remembered. `filad` is on-demand and a miss
            // right after a respring is normal — remembering it would mark every
            // file on the first screen as picture-less for the life of the process,
            // and nothing in the key would ever change to let them recover.
            let descriptor = try await open()
            guard descriptor >= 0 else { throw POSIXError(.EBADF) }
            defer { close(descriptor) }
            return await render(descriptor: descriptor, name: (path as NSString).lastPathComponent, maxPixelSize: maxPixelSize)
        }
    }

    /// QuickLook's thumbnail of the file at `path`, or nil. For the types
    /// `thumbnail` does not draw; it shares that call's bound and cache.
    ///
    /// Only a path this process can read: QuickLook reads it by path, as this
    /// app, and turns an unreadable text file into a blank page rather than a
    /// failure. A type with no thumbnailer fails, and that is remembered.
    public func quickLookThumbnail(path: String, modified: Double, byteCount: Int64, maxPixelSize: Int = 160) async -> CGImage? {
        #if canImport(QuickLookThumbnailing)
            guard byteCount > 0, byteCount <= PreviewLimits.fileByteCount, maxPixelSize > 0, maxPixelSize <= 512 else { return nil }
            let key = "ql:\(path)@\(modified.bitPattern)@\(byteCount)@\(maxPixelSize)" as NSString
            return await generate(key) {
                // Not remembered: permissions change, and a chmod keeps the key.
                guard access(path, R_OK) == 0 else { throw POSIXError(.EACCES) }
                // Off this actor, like the decoders: the request is a round trip
                // to QuickLook's own process.
                return await Task.detached(priority: .utility) {
                    let request = QLThumbnailGenerator.Request(
                        fileAt: URL(fileURLWithPath: path),
                        size: CGSize(width: maxPixelSize, height: maxPixelSize),
                        scale: 1,
                        representationTypes: .thumbnail
                    )
                    return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
                }.value
            }
        #else
            return nil
        #endif
    }

    /// The cache and the bound around one generation. `make` runs at most
    /// once, only on a miss and only in a free slot. Its nil means "nothing to
    /// draw" and is remembered; a throw means "not now" and is not.
    private func generate(_ key: NSString, _ make: () async throws -> CGImage?) async -> CGImage? {
        if let hit = images.object(forKey: key) {
            return hit
        }
        if failures.object(forKey: key) != nil {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }

        let made: CGImage?
        do { made = try await make() } catch { return nil }
        guard let image = made else {
            failures.setObject(NSNull(), forKey: key)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Content sniffing must not expand the decoder surface selected by the
    /// file's name during background browsing. Mismatches keep the type icon.
    ///
    /// The size comes from `fstat` on the descriptor rather than from the
    /// listing the caller quoted: a file being appended to between the two — a
    /// log, a download in progress — would otherwise have its own reader told a
    /// length that is no longer true.
    private func render(descriptor: Int32, name: String, maxPixelSize: Int) async -> CGImage? {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0 else { return nil }
        let byteCount = Int64(status.st_size)
        guard byteCount <= PreviewLimits.fileByteCount else { return nil }

        var head = Data(count: FileFormat.detectionByteCount)
        let read = head.withUnsafeMutableBytes { raw in
            pread(descriptor, raw.baseAddress, FileFormat.detectionByteCount, 0)
        }
        guard read > 0 else { return nil }

        // Decoding is synchronous CPU work and runs off this actor, or a cache
        // lookup for the next row waits behind it.
        let declared = FileFormat.detect(head: Data(), name: name)
        let detected = FileFormat.detect(head: head.prefix(read), name: name)
        guard declared == detected else { return nil }
        switch detected {
        case .image:
            return await Task.detached(priority: .utility) {
                DescriptorImage.thumbnail(descriptor: descriptor, byteCount: byteCount, maxPixelSize: maxPixelSize)
            }.value
        case .pdf:
            return await Task.detached(priority: .utility) {
                DescriptorImage.firstPage(descriptor: descriptor, byteCount: byteCount, maxPixelSize: maxPixelSize)
            }.value
        case .video:
            // Its own descriptor, because the asset outlives this call by as
            // long as AVFoundation keeps reading and `thumbnail` closes ours.
            let copy = dup(descriptor)
            guard copy >= 0 else { return nil }
            return await DescriptorAsset(descriptor: copy, name: name).frame(maxPixelSize: maxPixelSize)
        case .audio, .propertyList, .machO, .archive, .sqlite, .text, .binary:
            // Audio artwork is a real thumbnail and deliberately absent: it
            // means loading the asset's metadata for every track in a folder,
            // and the waveform icon already says what the file is.
            return nil
        }
    }

    // MARK: - The bound

    private func acquire() async {
        guard active >= Self.concurrencyLimit else {
            active += 1
            return
        }
        // A cancelled task parks here like any other and is woken in turn; it
        // then sees `Task.isCancelled` and returns without opening anything.
        // Waking it costs a resume, and not waking it would leak the slot.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            // The slot is handed straight over rather than freed and retaken,
            // which is what keeps `active` honest under contention.
            waiting.removeFirst().resume()
        }
    }

    /// In-flight generations, for the test that proves the bound holds.
    var activeCount: Int {
        active
    }
}
