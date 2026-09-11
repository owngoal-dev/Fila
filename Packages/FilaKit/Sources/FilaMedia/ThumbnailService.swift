import CoreGraphics
import FilaFormats
import Foundation
#if canImport(QuickLookThumbnailing)
    import QuickLookThumbnailing
    import UniformTypeIdentifiers
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
/// own process, as this app. Measured on the device, a path the app cannot read
/// is not a failure there but a blank page. So `quickLookThumbnail` hands it
/// the path only when this process can read it, and otherwise a small copy
/// made through the descriptor the daemon opened, in an app-owned directory
/// that is removed again the moment QuickLook answers.
///
/// QuickLook also draws the OS's own picture of a type (`quickLookIcon`): the
/// app ships no artwork for files, and asks the system it runs on instead.
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
    ///
    /// `square` cuts the picture to the square a cell shows (`SquareImage`); a
    /// preview wants it whole.
    public func thumbnail(
        path: String,
        modified: Double,
        byteCount: Int64,
        maxPixelSize: Int = 160,
        square: Bool = false,
        open: @escaping @Sendable () async throws -> Int32
    ) async -> CGImage? {
        guard byteCount > 0, maxPixelSize > 0, maxPixelSize <= 512 else { return nil }
        let key = "\(path)@\(modified.bitPattern)@\(byteCount)@\(maxPixelSize)\(square ? "@square" : "")" as NSString
        return await generate(key) {
            // A failed open is never remembered. `filad` is on-demand and a miss
            // right after a respring is normal — remembering it would mark every
            // file on the first screen as picture-less for the life of the process,
            // and nothing in the key would ever change to let them recover.
            let descriptor = try await open()
            guard descriptor >= 0 else { throw POSIXError(.EBADF) }
            defer { close(descriptor) }
            let name = (path as NSString).lastPathComponent
            guard case let (image, anchor)? = await render(descriptor: descriptor, name: name, maxPixelSize: maxPixelSize)
            else { return nil }
            return square ? SquareImage.make(image, anchor: anchor, maxSide: maxPixelSize) : image
        }
    }

    /// The largest file copied for QuickLook when this process cannot read it.
    /// Staging is a whole copy on flash for every such row scrolled past, so
    /// it is kept to the size of an ordinary document.
    static let stagedByteCount: Int64 = 10 * 1024 * 1024

    /// QuickLook's thumbnail of the file at `path`, or nil. For the types
    /// `thumbnail` does not draw; it shares that call's bound and cache. A
    /// type with no thumbnailer fails, and that is remembered.
    ///
    /// A path this process can read goes to QuickLook as it is. Any other is
    /// copied first — through the descriptor `open` returns, into the empty
    /// app-owned directory `workspace` makes — because QuickLook reads as this
    /// app and turns an unreadable file into a blank page, not a failure. The
    /// directory is removed once QuickLook has answered, on every path out,
    /// cancellation included. A file over `stagedByteCount`, a refused open or
    /// a failed copy is "not now", never remembered: permissions change, and a
    /// chmod keeps the key.
    public func quickLookThumbnail(
        path: String,
        modified: Double,
        byteCount: Int64,
        maxPixelSize: Int = 160,
        square: Bool = false,
        workspace: @escaping @Sendable () async throws -> URL,
        open: @escaping @Sendable () async throws -> Int32
    ) async -> CGImage? {
        #if canImport(QuickLookThumbnailing)
            guard byteCount > 0, byteCount <= PreviewLimits.fileByteCount, maxPixelSize > 0, maxPixelSize <= 512 else { return nil }
            let key = "ql:\(path)@\(modified.bitPattern)@\(byteCount)@\(maxPixelSize)\(square ? "@square" : "")" as NSString
            return await generate(key) {
                let page: CGImage?
                if access(path, R_OK) == 0 {
                    page = await Self.quickLook(URL(fileURLWithPath: path), maxPixelSize: maxPixelSize, types: .thumbnail)
                } else {
                    guard byteCount <= Self.stagedByteCount else { throw POSIXError(.EFBIG) }
                    let descriptor = try await open()
                    guard descriptor >= 0 else { throw POSIXError(.EBADF) }
                    defer { close(descriptor) }
                    let directory = try await workspace()
                    // Declared after the descriptor's, so it runs first: QuickLook
                    // has answered by then, and nothing reads the copy any more.
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let copy = directory.appendingPathComponent((path as NSString).lastPathComponent)
                    try await Task.detached(priority: .utility) {
                        try Self.copy(descriptor, to: copy, limit: Self.stagedByteCount)
                    }.value
                    try Task.checkCancellation()
                    page = await Self.quickLook(copy, maxPixelSize: maxPixelSize, types: .thumbnail)
                }
                guard let page else { return nil }
                return square ? SquareImage.make(page, anchor: .top, maxSide: maxPixelSize) : page
            }
        #else
            return nil
        #endif
    }

    /// The picture the OS draws for the type of the item at `path` — QuickLook's
    /// icon, not its content — as a square of `maxPixelSize`. `contentType`
    /// overrides the type the name implies. No byte of the item is read, so
    /// `path` is a probe the caller made: an empty file or directory whose name
    /// carries the type.
    public func quickLookIcon(path: String, contentType: String? = nil, maxPixelSize: Int) async -> CGImage? {
        #if canImport(QuickLookThumbnailing)
            guard maxPixelSize > 0, maxPixelSize <= 1024 else { return nil }
            let key = "icon:\(contentType ?? ""):\(path)@\(maxPixelSize)" as NSString
            return await generate(key) {
                let icon = await Self.quickLook(
                    URL(fileURLWithPath: path),
                    maxPixelSize: maxPixelSize,
                    types: .icon,
                    contentType: contentType
                )
                return icon.flatMap { SquareImage.make($0, anchor: .center, maxSide: maxPixelSize) }
            }
        #else
            return nil
        #endif
    }

    #if canImport(QuickLookThumbnailing)
        /// One QuickLook request, off this actor like the decoders: it is a
        /// round trip to QuickLook's own process. Detached, so a cancelled row
        /// still waits for the answer before its staged copy is removed.
        private static func quickLook(
            _ url: URL,
            maxPixelSize: Int,
            types: QLThumbnailGenerator.Request.RepresentationTypes,
            contentType: String? = nil
        ) async -> CGImage? {
            await Task.detached(priority: .utility) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: maxPixelSize, height: maxPixelSize),
                    scale: 1,
                    representationTypes: types
                )
                if let contentType, let type = UTType(contentType) {
                    request.contentType = type
                }
                return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            }.value
        }
    #endif

    /// Copies a regular file of at most `limit` bytes from `descriptor` into a
    /// new file at `target`, which must not exist. The size is `fstat`ed off the
    /// descriptor, and a file that grows past the limit mid-copy fails rather
    /// than being cut short into a different picture.
    private static func copy(_ descriptor: Int32, to target: URL, limit: Int64) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard Int64(status.st_size) <= limit else { throw POSIXError(.EFBIG) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard count > 0 else { return }
            offset += off_t(count)
            guard Int64(offset) <= limit else { throw POSIXError(.EFBIG) }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += result
            }
        }
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
    ///
    /// The anchor is where a square of the picture belongs: a page's is its top.
    private func render(descriptor: Int32, name: String, maxPixelSize: Int) async -> (CGImage, SquareImage.Anchor)? {
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
            }.value.map { ($0, .center) }
        case .pdf:
            return await Task.detached(priority: .utility) {
                DescriptorImage.firstPage(descriptor: descriptor, byteCount: byteCount, maxPixelSize: maxPixelSize)
            }.value.map { ($0, .top) }
        case .video:
            // Its own descriptor, because the asset outlives this call by as
            // long as AVFoundation keeps reading and `thumbnail` closes ours.
            let copy = dup(descriptor)
            guard copy >= 0 else { return nil }
            return await DescriptorAsset(descriptor: copy, name: name).frame(maxPixelSize: maxPixelSize).map { ($0, .center) }
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
