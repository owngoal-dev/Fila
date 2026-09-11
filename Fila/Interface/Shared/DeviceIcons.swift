import FilaMedia
import Foundation
import UIKit

/// Pictures of the file types no artwork matches, drawn by the OS the app
/// runs on. Two public sources, both on every supported OS:
///
/// - QuickLook's `.icon` of a probe — an empty file in the app's caches whose
///   name carries the type — asked through `ThumbnailService`, off the main
///   thread.
/// - `UIDocumentInteractionController.icons`: synchronous, by extension alone.
///   It costs about 20 ms of main thread the first time an extension is asked
///   for, so it answers only a miss.
///
/// Synchronous callers — a row, a menu, a breadcrumb — draw out of `cache`.
/// `prewarm()` asks QuickLook for the likeliest of those types in the
/// background at launch. A lookup is never nil and never a symbol.
///
/// Measured on iOS 26 (vphone): no picture changes with the appearance, so the
/// cache is keyed by type alone; QuickLook's icon of a file type takes about
/// 25 ms cold and none warm.
@MainActor
enum DeviceIcons {
    /// The side a cached picture is drawn at: the grid's 64 points at 3×. A
    /// row, a menu and a breadcrumb scale it down.
    static let side = 192
    /// The properties page's 192 points at 3×.
    static let largeSide = 576

    private static var cache: [String: UIImage] = [:]

    /// `type` is a lowercased extension, empty for none.
    static func image(for type: String) -> UIImage {
        if let hit = cache[type] {
            return hit
        }
        let image = interactionIcon(for: type)
        cache[type] = image
        return image
    }

    /// The properties page's picture: QuickLook's at `largeSide`, or the
    /// cached one when QuickLook has none.
    static func largeImage(for type: String) async -> UIImage {
        await quickLookImage(for: type, side: largeSide) ?? image(for: type)
    }

    /// Asks QuickLook for the types a listing is likeliest to show that no
    /// artwork matches, one at a time in the background, so the interaction
    /// controller's main thread cost is paid only for the rare ones.
    static func prewarm() {
        Task(priority: .utility) {
            for type in commonTypes {
                if let image = await quickLookImage(for: type, side: side) {
                    cache[type] = image
                }
            }
        }
    }

    /// The empty type first: every file without an extension, or with one
    /// the OS declares no type for, which on this filesystem is most of them.
    private static let commonTypes = ["", "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub"]

    private static func quickLookImage(for type: String, side: Int) async -> UIImage? {
        guard let probe = probePath(for: type),
              let icon = await ThumbnailService.shared.quickLookIcon(path: probe, maxPixelSize: side)
        else { return nil }
        // Full colour, never tinted: a list configuration tints an image left
        // on `.automatic`.
        return UIImage(cgImage: icon, scale: 3, orientation: .up).withRenderingMode(.alwaysOriginal)
    }

    /// The interaction controller's picture of the type. It looks only at the
    /// name, so the path need not exist.
    private static func interactionIcon(for type: String) -> UIImage {
        let url = URL(fileURLWithPath: type.isEmpty ? "/probe" : "/probe.\(type)")
        let icons = UIDocumentInteractionController(url: url).icons
        let largest = icons.max { $0.size.width * $0.scale < $1.size.width * $1.scale }
        // The controller always has a picture; the empty image is only here so
        // that a lookup can promise one.
        return (largest ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }

    /// The probe QuickLook is asked about: made on first use, empty, and never
    /// written again.
    private static func probePath(for type: String) -> String? {
        guard let probes else { return nil }
        let path = probes.appendingPathComponent(type.isEmpty ? "file" : "file.\(type)").path
        // Never truncates, never follows a link someone left in its place.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        close(descriptor)
        return path
    }

    /// Under the app's caches rather than the temporary workspace: the probes
    /// outlive a launch on purpose, and they are needed before the first
    /// handshake, which the workspace waits for.
    private static let probes: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("wiki.qaq.fila/DeviceIconProbes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { return nil }
        return directory
    }()
}
