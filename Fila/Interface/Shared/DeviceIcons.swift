import FilaMedia
import Foundation
import UIKit

/// Pictures of files, folders and types, drawn by the OS the app runs on.
///
/// The app ships no Apple artwork for these. Copying the Mac's icons into the
/// bundle is redistributing them; asking the running system for its own is
/// not, costs the bundle nothing, and draws what every other app on the device
/// draws for the same file. Two public sources, both on every supported OS:
///
/// - QuickLook's `.icon` of a probe — an empty file or directory in the app's
///   caches whose name, or the content type it is given, carries the type —
///   asked through `ThumbnailService`, off the main thread. The only public
///   source of a folder, an app bundle, a Mach-O executable and the "?" page of
///   something the OS cannot name.
/// - `UIDocumentInteractionController.icons`: synchronous, by extension alone,
///   a file type's picture. It costs about 20 ms of main thread the first time
///   an extension is asked for, so it answers only a miss.
///
/// Synchronous callers — a row, the sidebar, a menu, a breadcrumb — draw out of
/// `cache`. `prepare()` fills it at launch with what only QuickLook draws,
/// before any screen exists, then asks QuickLook for the common file types in
/// the background. A lookup is never nil and never a symbol.
///
/// Measured on iOS 26 (vphone): no picture changes with the appearance, so the
/// cache is keyed by subject alone; QuickLook's icon of a folder takes about
/// 130 ms cold and a few warm, a file type's about 25 ms cold and none warm.
@MainActor
enum DeviceIcons {
    enum Subject: Hashable {
        case folder
        /// A directory the OS draws by its extension: `app`, `kext`, `framework`.
        case bundle(String)
        /// A regular file, by its lowercased extension; empty for none.
        case file(String)
        /// Mach-O content, whatever its name says.
        case executable
        /// Something the OS cannot name: a dangling link, a fifo, a device.
        case unknown
    }

    /// The side a cached picture is drawn at: the grid's 64 points at 3×. A
    /// row, a menu and a breadcrumb scale it down.
    static let side = 192
    /// The properties page's 192 points at 3×.
    static let largeSide = 576

    private static var cache: [Subject: UIImage] = [:]

    static func image(for subject: Subject) -> UIImage {
        if let hit = cache[subject] {
            return hit
        }
        let image = interactionIcon(for: subject)
        cache[subject] = image
        return image
    }

    /// The properties page's picture: QuickLook's at `largeSide`, or the
    /// cached one when QuickLook has none.
    static func largeImage(for subject: Subject) async -> UIImage {
        await quickLookImage(for: subject, side: largeSide) ?? image(for: subject)
    }

    /// Resolves what only QuickLook draws before the first scene connects, so
    /// the sidebar and the first listing draw real folders from their first
    /// frame, then prewarms the common file types in the background.
    ///
    /// It blocks: warm this is a few milliseconds, and a one-second bound
    /// keeps a QuickLook that never answers from holding the launch. A subject
    /// that misses the bound lands in the cache when it does answer; until
    /// then it draws the interaction controller's page.
    static func prepare() {
        defer { prewarm() }
        let subjects: [Subject] = [.folder, .bundle("app"), .bundle("kext"), .bundle("framework"), .executable, .unknown]
        let requests = subjects.compactMap { subject in probePath(for: subject).map { (subject, $0.path, $0.contentType) } }
        let side = Self.side
        let answers = Answers()
        let done = DispatchSemaphore(value: 0)
        // Detached: a task started here would belong to the main actor, which
        // is exactly what is about to wait for it.
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for (subject, path, contentType) in requests {
                    group.addTask {
                        if let icon = await ThumbnailService.shared.quickLookIcon(
                            path: path,
                            contentType: contentType,
                            maxPixelSize: side
                        ) {
                            answers.set(icon, for: subject)
                        }
                    }
                }
            }
            done.signal()
            await MainActor.run { store(answers) }
        }
        _ = done.wait(timeout: .now() + 1)
        store(answers)
    }

    /// Asks QuickLook for the file types a listing is most likely to show,
    /// one at a time in the background, so the interaction controller's main
    /// thread cost is paid only for the rare ones.
    private static func prewarm() {
        Task(priority: .utility) {
            for type in commonExtensions {
                if let image = await quickLookImage(for: .file(type), side: side) {
                    cache[.file(type)] = image
                }
            }
        }
    }

    private static let commonExtensions = [
        "txt", "md", "rtf", "log", "csv", "json", "xml", "plist", "yaml", "html", "css", "js",
        "swift", "c", "h", "m", "cpp", "py", "sh", "pdf", "png", "jpg", "jpeg", "heic", "gif",
        "webp", "tiff", "svg", "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "flac", "zip",
        "gz", "tar", "7z", "rar", "deb", "ipa", "docx", "xlsx", "pptx", "pages", "numbers",
        "key", "epub", "ttf", "otf", "dylib", "crash", "sqlite", "db",
    ]

    private static func store(_ answers: Answers) {
        for (subject, icon) in answers.all {
            cache[subject] = picture(icon)
        }
    }

    private static func quickLookImage(for subject: Subject, side: Int) async -> UIImage? {
        guard let probe = probePath(for: subject),
              let icon = await ThumbnailService.shared.quickLookIcon(
                  path: probe.path,
                  contentType: probe.contentType,
                  maxPixelSize: side
              )
        else { return nil }
        return picture(icon)
    }

    /// Full colour, never tinted: a list configuration tints an image left
    /// on `.automatic`.
    private static func picture(_ icon: CGImage) -> UIImage {
        UIImage(cgImage: icon, scale: 3, orientation: .up).withRenderingMode(.alwaysOriginal)
    }

    /// The interaction controller's picture of the subject's type. It looks
    /// only at the name, so the path need not exist; a directory it draws as a
    /// blank page, which is only ever the answer when QuickLook had none.
    private static func interactionIcon(for subject: Subject) -> UIImage {
        let name = switch subject {
        case let .file(type): type.isEmpty ? "probe" : "probe.\(type)"
        case let .bundle(type): "probe.\(type)"
        case .folder, .executable, .unknown: "probe"
        }
        let url = URL(fileURLWithPath: "/" + name, isDirectory: subject == .folder)
        let icons = UIDocumentInteractionController(url: url).icons
        let largest = icons.max { $0.size.width * $0.scale < $1.size.width * $1.scale }
        // The controller always has a picture; the empty image is only here so
        // that a lookup can promise one.
        return (largest ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }

    /// The probe QuickLook is asked about — made on first use, empty, and
    /// never written again — and the content type it is told the probe is.
    /// Directories and files get different names, so `bundle("app")` and
    /// `file("app")` can never ask about the same entry.
    private static func probePath(for subject: Subject) -> (path: String, contentType: String?)? {
        let (name, isDirectory, contentType): (String, Bool, String?) = switch subject {
        case .folder: ("folder", true, nil)
        case let .bundle(type): ("bundle.\(type)", true, nil)
        case let .file(type): (type.isEmpty ? "file" : "file.\(type)", false, nil)
        case .executable: ("file", false, "public.unix-executable")
        case .unknown: ("file", false, "public.item")
        }
        guard let probes else { return nil }
        let path = probes.appendingPathComponent(name).path
        if isDirectory {
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { return nil }
        } else {
            // Never truncates, never follows a link someone left in its place.
            let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return nil }
            close(descriptor)
        }
        return (path, contentType)
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

/// QuickLook's answers to `prepare`, written from its tasks and read on the
/// main thread once they are done or the wait is over.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var icons: [DeviceIcons.Subject: CGImage] = [:]

    func set(_ icon: CGImage, for subject: DeviceIcons.Subject) {
        lock.lock()
        defer { lock.unlock() }
        icons[subject] = icon
    }

    var all: [DeviceIcons.Subject: CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return icons
    }
}
