import FilaFormats
import FilaMedia
import FilaProtocol
import UIKit

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
        /// The OS's picture of what the file is: drawn whole, the way the type
        /// icon it replaces is.
        case icon(UIImage)
        /// The file's own content. A cell's is already square (`SquareImage`)
        /// and is drawn with the thumbnail edge; the properties page's is whole.
        case thumbnail(UIImage)
    }

    /// Whether any tier can answer for this node: a regular file, or a link
    /// that resolves to one. A cell asks before it spends its reuse token, so a
    /// folder's application artwork load is not cancelled for nothing.
    static func canHavePicture(_ node: FileNode) -> Bool {
        node.kind == .regular || node.link?.resolvedKind == .regular
    }

    /// `large` is the properties page: a 512 px thumbnail of any regular file,
    /// whole. A row or grid cell gets a 160 px square of an image only — the
    /// other decoders cost too much to run for every file scrolled past. Both
    /// get QuickLook's page of a type no artwork matches; it runs in
    /// QuickLook's process.
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
        let side = large ? 512 : 160
        let open: @Sendable () async throws -> Int32 = {
            try await session.perform(retryOnDisconnect: true) {
                try await $0.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            }
        }
        if large || format(of: node) == .image,
           let image = await ThumbnailService.shared.thumbnail(
               path: path,
               modified: node.modified,
               byteCount: node.size,
               maxPixelSize: side,
               square: !large,
               open: open
           ) {
            return Task.isCancelled ? nil : .thumbnail(UIImage(cgImage: image))
        }
        // 3. QuickLook's page, for a declared type no artwork matches — an
        //    office document, say. A type with artwork keeps it: QuickLook's
        //    page of a text file or a plist is a near-blank square, and an
        //    unknown extension, or none, has no thumbnailer at all. A file
        //    this process cannot read is staged into its own workspace.
        guard case let .device(type) = icon(for: node), !type.isEmpty,
              let page = await ThumbnailService.shared.quickLookThumbnail(
                  path: path,
                  modified: node.modified,
                  byteCount: node.size,
                  maxPixelSize: side,
                  square: !large,
                  workspace: { try await session.makeTemporaryDirectory() },
                  open: open
              ),
              !Task.isCancelled else { return nil }
        return .thumbnail(UIImage(cgImage: page))
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
        return large ? largeImage(for: .artwork("executable")) : image(for: .artwork("executable"))
    }
}

extension FilePresentation {
    /// A whole thumbnail for the properties page, with the hairline edge drawn
    /// into it. The page shows it at its own aspect inside a square box, so a
    /// view's border would frame the box rather than the picture.
    static func edged(_ thumbnail: UIImage) -> UIImage {
        let bounds = CGRect(origin: .zero, size: thumbnail.size)
        let format = UIGraphicsImageRendererFormat.preferred().with { $0.scale = thumbnail.scale }
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            thumbnail.draw(in: bounds)
            UIColor(white: 0, alpha: 0.15).setStroke()
            context.cgContext.setLineWidth(1 / thumbnail.scale)
            context.stroke(bounds.insetBy(dx: 0.5 / thumbnail.scale, dy: 0.5 / thumbnail.scale))
        }.withRenderingMode(.alwaysOriginal)
    }
}

extension UIImageView {
    /// Draws a file's picture the way every cell draws one: an icon whole, a
    /// thumbnail filling its square with rounded corners and a hairline edge —
    /// a white page on a white row has no edge of its own.
    func show(_ picture: FilePresentation.Picture) {
        switch picture {
        case let .icon(image):
            showIcon(image)
        case let .thumbnail(image):
            self.image = image
            contentMode = .scaleAspectFill
            clipsToBounds = true
            layer.cornerRadius = 4
            layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
            layer.borderColor = UIColor(white: 0, alpha: 0.15).cgColor
        }
    }

    /// A type icon, with everything `show` sets for a thumbnail put back — the
    /// state a reused cell starts from.
    func showIcon(_ image: UIImage?) {
        self.image = image
        contentMode = .scaleAspectFit
        clipsToBounds = false
        layer.cornerRadius = 0
        layer.borderWidth = 0
    }
}
