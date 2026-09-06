import AVFoundation
import FilaFormats
import Foundation
import UniformTypeIdentifiers

/// An `AVAsset` that reads through a descriptor `filad` opened, and never
/// through a path.
///
/// `AVPlayer` takes a URL, the file is usually somewhere `mobile` cannot open,
/// and the daemon hands back a descriptor rather than a path — so the URL here
/// is a made-up one under a scheme AVFoundation does not know, and every byte
/// it asks for is answered by `pread` on the descriptor. Nothing is copied,
/// there is no size ceiling, and the bytes go kernel → app → decoder exactly as
/// they do in every other viewer.
///
/// Two things that look like alternatives and are not:
///
/// - `file:///dev/fd/<n>` is the obvious first try and it does not work. Bare,
///   AVFoundation refuses it ("This media format is not supported", -11828):
///   the fdesc node has no extension and nothing sniffs it. Behind a symlink
///   that carries the real extension AVFoundation *does* play it — but
///   `open("/dev/fd/<n>")` re-runs the permission check against the underlying
///   file rather than duplicating the descriptor, so on the one file that
///   matters — root-owned, mode 600 — it fails with `EACCES`, which is the
///   whole reason the daemon opened it for us. Measured on macOS 27, both.
/// - Copying into the app container works and is what this replaces. A file
///   manager plays 4 GB videos; a phone does not have room, and the user should
///   not wait for a copy to scrub to the middle of a film.
public final class DescriptorAsset {
    /// Hand this to `AVPlayer`. Its bytes come from the descriptor, so it stays
    /// valid exactly as long as this object does.
    public let asset: AVURLAsset

    private let reader: DescriptorResourceLoader

    /// Takes ownership of `descriptor` and closes it when released. Callers that
    /// still need theirs pass a `dup(2)`.
    ///
    /// `name` is only ever used to name the content type: AVFoundation will not
    /// open an asset whose type it cannot determine, and a made-up URL tells it
    /// nothing. An extensionless file falls back to the container signature.
    public init(descriptor: Int32, name: String) {
        var status = stat()
        let byteCount = fstat(descriptor, &status) == 0 ? Int64(status.st_size) : 0
        reader = DescriptorResourceLoader(
            descriptor: descriptor,
            byteCount: byteCount,
            contentType: DescriptorAsset.contentType(descriptor: descriptor, name: name)
        )

        var components = URLComponents()
        components.scheme = DescriptorResourceLoader.scheme
        components.host = "descriptor"
        components.path = "/" + String(descriptor)
        asset = AVURLAsset(url: components.url!)
        // The loader is held weakly here, which is why this class owns it.
        asset.resourceLoader.setDelegate(reader, queue: DescriptorResourceLoader.queue)
    }

    /// A still from a second or so in, at most `maxPixelSize` on its long edge.
    /// Nil for anything with no visual track — an MP3 has none — and nil rather
    /// than a throw for anything that failed, because a thumbnail that could not
    /// be made is not news.
    public func frame(maxPixelSize: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Unbounded tolerance so the generator takes whatever sync sample is
        // nearest instead of decoding forward to an exact frame — a thumbnail
        // does not care which frame it got, and the exact one costs a decode of
        // every frame before it. A short clip simply clamps to its last.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // `generateCGImagesAsynchronously` rather than the `async` `image(at:)`,
        // which is iOS 16 and this app ships to 15. One time asked for is one
        // callback, so the continuation resumes exactly once.
        let at = CMTime(seconds: 1, preferredTimescale: 600)
        let image = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: at)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
        // A released generator cancels the request it is running, which would
        // read as a thumbnail that silently never arrives. Nothing above holds
        // it, so the lifetime is stated here rather than parked in a property.
        withExtendedLifetime(generator) {}
        return image
    }

    /// The UTI AVFoundation is told the bytes are, by extension first and by the
    /// container's own signature second — same order, and for the same reason,
    /// as `FileFormat.detect`: half the interesting files on a jailbroken
    /// filesystem have no extension.
    private static func contentType(descriptor: Int32, name: String) -> String {
        let suffix = (name as NSString).pathExtension
        if !suffix.isEmpty, let type = UTType(filenameExtension: suffix),
           type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        var head = [UInt8](repeating: 0, count: 16)
        let got = head.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 16, 0) }
        guard got >= 12 else { return UTType.audiovisualContent.identifier }
        // ISO base media: "ftyp" at offset 4, brand at 8. `qt  ` is a QuickTime
        // movie and everything else in practice is MP4-family.
        if Array(head[4 ..< 8]) == Array("ftyp".utf8) {
            return Array(head[8 ..< 12]) == Array("qt  ".utf8)
                ? UTType.quickTimeMovie.identifier
                : UTType.mpeg4Movie.identifier
        }
        // An ID3 tag, or a bare MPEG frame sync — eleven set bits across the
        // first two bytes, which is all an MP3 without a tag has to say for
        // itself.
        if Array(head[0 ..< 3]) == Array("ID3".utf8) || (head[0] == 0xFF && head[1] & 0xE0 == 0xE0) {
            return UTType.mp3.identifier
        }
        if Array(head[0 ..< 4]) == Array("RIFF".utf8) { return UTType.wav.identifier }
        if Array(head[0 ..< 4]) == Array("FORM".utf8) { return UTType.aiff.identifier }
        if Array(head[0 ..< 4]) == Array("caff".utf8) { return "com.apple.coreaudio-format" }
        return UTType.audiovisualContent.identifier
    }
}

/// Answers AVFoundation's byte-range requests out of the descriptor.
///
/// Every request is `pread` at the offset it asked for — never `read` plus a
/// seek — because AVFoundation issues several at once from its own threads and
/// a shared file offset between them is a corrupted stream.
private final class DescriptorResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// Anything AVFoundation has no opinion about. The URL is a handle, not a
    /// location: nothing resolves it and nothing else may.
    static let scheme = "fila-descriptor"
    /// Concurrent, because AVFoundation has several requests outstanding at
    /// once and each one is an independent `pread`. A serial queue would make
    /// the last of them wait out all the others for no reason.
    static let queue = DispatchQueue(label: "wiki.qaq.fila.media.loader", attributes: .concurrent)

    /// The most any one request is answered with before it is finished, whether
    /// it asked for that much or for the rest of the file.
    ///
    /// AVFoundation asks in tens of megabytes and, for the first request of all,
    /// for everything to the end — answering either literally on a 4 GB film is
    /// the copy this class exists to avoid. A short answer is legal: it re-asks
    /// at the new offset until it has what it wanted. Measured over a full
    /// `AVAssetReader` pass of an 82 MB movie: capping here took the bytes
    /// handed to AVFoundation from 219 MB to 95 MB with every sample still
    /// delivered, and holds resident memory to one `readByteCount` per request.
    private static let responseByteCount: Int64 = 8 * 1_024 * 1_024
    /// One `pread` at a time, so a request is answered out of a buffer this size
    /// rather than out of one the size of the answer.
    private static let readByteCount: Int64 = 1 * 1_024 * 1_024

    private let descriptor: Int32
    private let byteCount: Int64
    private let contentType: String

    init(descriptor: Int32, byteCount: Int64, contentType: String) {
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.contentType = contentType
    }

    deinit { close(descriptor) }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = request.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = byteCount
            // Without this AVFoundation treats the asset as a stream it must
            // read front to back, and scrubbing stops working.
            information.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }

        // `currentOffset` rather than `requestedOffset`: a request that has
        // already been answered in part resumes where it stopped, and for a
        // fresh one the two are the same.
        var offset = data.currentOffset
        let asked = data.requestsAllDataToEndOfResource
            ? byteCount
            : data.requestedOffset + Int64(data.requestedLength)
        let end = min(byteCount, min(asked, offset + Self.responseByteCount))

        let bufferByteCount: Int64 = min(Self.readByteCount, max(end - offset, 1))
        var buffer = Data(count: Int(bufferByteCount))
        while offset < end, !request.isCancelled {
            let want = Int(min(bufferByteCount, end - offset))
            var got = -1
            // `errno` is read inside the closure: `withUnsafeMutableBytes` is
            // mutating on `Data` and may run a uniqueness check on the way out,
            // which is free to clobber it before we look.
            var failure: Int32 = EIO
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                repeat {
                    got = pread(descriptor, base, want, off_t(offset))
                    failure = errno
                } while got < 0 && failure == EINTR
            }
            // Short of the end of a file whose size we were told means the file
            // changed underneath us — a log rewritten, a download replaced. It
            // is an error and not an end: finishing empty makes AVFoundation ask
            // again at the same offset, for ever.
            if got <= 0 {
                request.finishLoading(with: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(got < 0 ? failure : EIO)
                ))
                return true
            }
            data.respond(with: buffer.prefix(got))
            offset += Int64(got)
        }

        // Finished even when `end` fell short of what was asked for: a short
        // answer is legal and AVFoundation re-asks from the new offset, which is
        // what keeps a 4 GB film from arriving in one response.
        if !request.isCancelled { request.finishLoading() }
        return true
    }
}
