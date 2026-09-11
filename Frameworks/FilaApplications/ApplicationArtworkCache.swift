import FilaCore
import UIKit

/// System-rendered application artwork, cached, for every row that shows
/// an app.
@MainActor
final class ApplicationArtworkCache: ApplicationArtwork {
    static let shared = ApplicationArtworkCache()

    private let icons: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    /// What a row shows for an app with no artwork, and while artwork loads:
    /// the app's generic application artwork, never a glyph.
    var placeholder: UIImage? {
        BackendScreens.shell?.fileIcon(named: "Application.app", isDirectory: true)
    }

    func cachedIcon(for identifier: String?) -> UIImage? {
        guard let identifier else { return placeholder }
        return icons.object(forKey: identifier as NSString)
    }

    /// Fetched off the main actor so IconServices' cache lookup and
    /// rendering do not stall scrolling.
    func icon(for identifier: String?) async -> UIImage? {
        guard let identifier else { return placeholder }
        if let image = icons.object(forKey: identifier as NSString) {
            return image
        }
        let scale = UIScreen.main.scale
        let image = await Task.detached(priority: .userInitiated) {
            ApplicationIconRenderer.image(for: identifier, scale: scale)
        }.value
        if let image {
            icons.setObject(image, forKey: identifier as NSString)
        }
        return image ?? placeholder
    }
}
