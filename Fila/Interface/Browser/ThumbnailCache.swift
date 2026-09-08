import FilaMedia
import FilaProtocol
import UIKit

/// The browser shares the bounded decoder queue and byte-budgeted cache used
/// by Properties. Rows never read a complete image or start their own decoder.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    nonisolated static let pixelSize = 160

    private init() {}

    func thumbnail(for path: String, node: FileNode, session: FileSession) async -> UIImage? {
        guard let image = await ThumbnailService.shared.thumbnail(
            path: path, modified: node.modified,
            byteCount: node.size, maxPixelSize: Self.pixelSize,
            open: {
                try await session.perform(retryOnDisconnect: true) {
                    try await $0.open(path, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                }
            }
        ), !Task.isCancelled else { return nil }
        return UIImage(cgImage: image)
    }
}
