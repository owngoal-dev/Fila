import FilaFormats
import FilaMedia
import FilaProtocol
import UIKit
import UniformTypeIdentifiers

/// A better picture than the type icon, made from the file itself.
///
/// Rows, the grid and the properties page all ask here, so the tiers are
/// written once: the first that answers wins, and nil means "keep the type
/// icon". A new tier is one more step in `picture(for:node:session:large:)`.
///
/// Every tier goes through `ThumbnailService`'s bounded queue and caches, so
/// a fast scroll never starts more reads than a screenful. Nothing here reads
/// a whole file or reports a failure: a picture is a convenience.
extension FilePresentation {
    enum Picture {
        /// Artwork: drawn whole, the way the type icon it replaces is.
        case icon(UIImage)
        /// The file's own content: fills its square and is clipped to it.
        case thumbnail(UIImage)
    }

    /// Whether any tier can answer for this node: a regular file, or a link
    /// that resolves to one. A cell asks before it spends its reuse token, so a
    /// folder's application artwork load is not cancelled for nothing.
    static func canHavePicture(_ node: FileNode) -> Bool {
        node.kind == .regular || node.link?.resolvedKind == .regular
    }

    /// `large` is the properties page: `-large` artwork, and a 512 px thumbnail
    /// of any regular file. A row or grid cell gets the 40pt artwork and a
    /// 160 px thumbnail of an image only — the other decoders cost too much to
    /// run for every file scrolled past. Both get QuickLook's page of a
    /// document the app can read itself; it runs in QuickLook's process.
    @MainActor
    static func picture(for path: String, node: FileNode, session: FileSession, large: Bool = false) async -> Picture? {
        guard canHavePicture(node) else { return nil }
        // 1. A Mach-O executable, from four magic bytes.
        if let executable = await executableImage(for: path, node: node, session: session, large: large) {
            return .icon(executable)
        }
        // 2. The content itself. Never through a link: the open refuses to
        //    follow one, and the cache key would be the link's own `lstat`.
        guard node.kind == .regular else { return nil }
        let format = format(of: node)
        let side = large ? 512 : 160
        if large || format == .image,
           let image = await ThumbnailService.shared.thumbnail(
               path: path,
               modified: node.modified,
               byteCount: node.size,
               maxPixelSize: side,
               open: {
                   try await session.perform(retryOnDisconnect: true) {
                       try await $0.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                   }
               }
           ) {
            return Task.isCancelled ? nil : .thumbnail(UIImage(cgImage: image))
        }
        // 3. QuickLook's page, for what the decoders above do not draw.
        guard quickLookDraws(node.name, format: format),
              let page = await ThumbnailService.shared.quickLookThumbnail(
                  path: path, modified: node.modified, byteCount: node.size, maxPixelSize: side
              ),
              !Task.isCancelled else { return nil }
        return .icon(framed(page))
    }

    /// Text, a property list, and any type the system declares — an office
    /// document, a font. Not audio: a song without artwork comes back as a
    /// generic note, worse than the artwork. An unknown extension, or none,
    /// has no thumbnailer, and asking would cost a round trip for every such row.
    private static func quickLookDraws(_ name: String, format: FileFormat) -> Bool {
        switch format {
        case .text, .propertyList:
            true
        case .binary:
            UTType(filenameExtension: (name as NSString).pathExtension).map { !$0.isDynamic } ?? false
        case .image, .pdf, .video, .audio, .archive, .sqlite, .machO:
            false
        }
    }

    /// A page is drawn whole, with the hairline edge the Files app gives one:
    /// a white page on a white row has no edge of its own.
    private static func framed(_ page: CGImage) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        let format = UIGraphicsImageRendererFormat.preferred().with { $0.scale = 1 }
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIImage(cgImage: page).draw(in: bounds)
            UIColor(white: 0, alpha: 0.15).setStroke()
            context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Four magic bytes, read in the app. A mode of 0777 also belongs to
    /// ordinary user documents, so the execute bits are not evidence.
    @MainActor
    private static func executableImage(
        for path: String,
        node: FileNode,
        session: FileSession,
        large: Bool
    ) async -> UIImage? {
        let found = await ThumbnailService.shared.isMachO(
            path: path,
            modified: node.modified,
            byteCount: node.kind == .symbolicLink ? 4 : node.size,
            cacheResult: node.kind != .symbolicLink
        ) {
            try await session.perform(retryOnDisconnect: true) {
                try await $0.open(path, flags: O_RDONLY | O_NONBLOCK | (node.kind == .symbolicLink ? 0 : O_NOFOLLOW))
            }
        }
        guard found, !Task.isCancelled else { return nil }
        return UIImage(
            named: large ? "FileIcons/executable-large" : "FileIcons/executable"
        )?.withRenderingMode(.alwaysOriginal)
    }
}
