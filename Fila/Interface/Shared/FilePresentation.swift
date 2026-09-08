import FilaFormats
import FilaMedia
import FilaProtocol
import Foundation
import UIKit

/// How a node reads in a list: its icon, its kind, its size and its date.
///
/// The initial icon comes from the name and
/// the `lstat` alone. `FileFormat.detect` with an empty head is exactly that —
/// the extension table without the signature table — which keeps one list of
/// extensions in the project instead of two that drift.
enum FilePresentation {
    /// Visible rows refine their fallback using four magic bytes in the app.
    /// A mode of 0777 also belongs to ordinary user documents, so it is not evidence.
    @MainActor
    static func executableImage(for path: String, node: FileNode, session: FileSession, large: Bool = false) async -> UIImage? {
        guard node.kind == .regular || node.link?.resolvedKind == .regular else { return nil }
        let found = await ThumbnailService.shared.isMachO(path: path, modified: node.modified,
                                                          byteCount: node.kind == .symbolicLink ? 4 : node.size, cacheResult: node.kind != .symbolicLink)
        {
            try await session.perform(retryOnDisconnect: true) {
                try await $0.open(path, flags: O_RDONLY | O_NONBLOCK | (node.kind == .symbolicLink ? 0 : O_NOFOLLOW))
            }
        }
        guard found, !Task.isCancelled else { return nil }
        return UIImage(named: large ? "FileIcons/executable-large" : "FileIcons/executable")?.withRenderingMode(.alwaysOriginal)
    }

    /// Which picture a row draws.
    ///
    /// Two cases because there are two kinds of artwork and they are drawn
    /// differently: `artwork` is a full-colour PNG out of the asset catalogue
    /// and must not be tinted, `symbol` is a template that takes the row's
    /// secondary colour. A single string would have collapsed that and made
    /// every folder grey.
    enum Icon: Hashable {
        /// A name under `Assets.xcassets/FileIcons`.
        case artwork(String)
        /// An SF Symbol, for the types the system has no distinct picture for.
        case symbol(String)
    }

    static func format(of node: FileNode) -> FileFormat {
        FileFormat.detect(head: Data(), name: node.name)
    }

    /// A colour icon wherever the system had one, and an SF Symbol wherever it
    /// did not.
    ///
    /// The line is drawn on whether the composed macOS icon says anything: a
    /// SQLite database and a symlink both compose to a blank sheet of paper, so
    /// they keep their glyph rather than ship artwork that reads as "unknown".
    ///
    /// A symlink draws whatever its *target* would draw. The badge that says it
    /// is a link is drawn over the corner by `IconRowCell`, not chosen here:
    /// this answers "which picture", the cell answers "with what on top of it".
    static func icon(for node: FileNode) -> Icon {
        guard node.kind != .symbolicLink else { return linkIcon(node) }
        return icon(kind: node.kind, name: node.name)
    }

    /// What a link points at, drawn as that.
    ///
    /// Costs nothing per row: the target string and the kind behind it are both
    /// already in the listing — `filaReadSymbolicLink` does the `readlinkat`
    /// and the following `fstatat` while it is building the node — so this is
    /// the same string lookup every other row does, run against the target
    /// instead of the link. No syscall, and no byte of any file is read.
    private static func linkIcon(_ node: FileNode) -> Icon {
        // A dangling link is the one case where the target's icon would be a
        // lie, and a jailbroken filesystem is full of them, so it keeps a
        // picture that says "there is nothing there" rather than borrowing one.
        guard let link = node.link, let kind = link.resolvedKind else {
            return .symbol("questionmark.square.dashed")
        }
        // The *target's* name: `latest -> release-3.2.png` is an image row.
        // `fstatat` follows the whole chain, so `kind` is never itself a link —
        // a loop comes back as ELOOP, which is the broken case above.
        return icon(kind: kind, name: (link.target as NSString).lastPathComponent)
    }

    private static func icon(kind: FileKind, name: String) -> Icon {
        let ext = (name as NSString).pathExtension.lowercased()
        switch kind {
        case .directory:
            // A bundle is a directory the user thinks of as one thing, and
            // showing `Foo.app` as a folder hides exactly the fact that makes
            // it interesting on a jailbroken device.
            switch ext {
            case "app": return .artwork("application")
            case "kext", "framework": return .artwork("kext")
            default: return .artwork("folder")
            }
        case .symbolicLink:
            // Unreachable: `icon(for:)` sends links to `linkIcon` and a
            // resolved kind is never a link. Here so the switch is total.
            return .symbol("arrowshape.turn.up.right")
        case .fifo, .socket, .blockDevice, .characterDevice:
            return .symbol("gearshape")
        case .regular, .unknown:
            break
        }
        // Presentation only: these stay whatever `FileFormat` says they are
        // for the viewer — a crash report opens as text — but draw as the
        // thing a person recognises them as.
        switch ext {
        case "ttf", "ttc", "otf", "dfont": return .artwork("font")
        case "ips", "crash", "panic", "hang", "spin", "diag": return .artwork("report")
        default: break
        }
        let format = FileFormat.detect(head: Data(), name: name)
        // Permissions do not identify content: new user files default to 0777.
        switch format {
        case .propertyList: return .artwork("plist")
        case .machO: return .artwork("executable")
        case .archive: return .artwork("archive")
        case .image: return .artwork("image")
        case .audio: return .artwork("audio")
        case .video: return .artwork("video")
        case .pdf: return .artwork("pdf")
        case .sqlite: return .symbol("cylinder")
        case .text: return .artwork("text")
        case .binary: return .artwork("document")
        }
    }

    /// The icon as a drawable image, at the size a row draws it.
    ///
    /// Cached, because this is called once per cell per scroll tick and a
    /// directory can hold 100k of them. The dictionary is the whole cache: a
    /// listing draws from at most a dozen distinct icons no matter how long it
    /// is, so there is nothing to evict and no cost in keeping them.
    /// `UIImage(named:)` has a cache of its own behind it; the point of this
    /// one is to skip the symbol configuration and the rendering-mode copy,
    /// which `UIImage` does not cache and which are the expensive half.
    @MainActor
    static func image(for node: FileNode) -> UIImage? {
        image(for: icon(for: node))
    }

    @MainActor
    static func image(kind: FileKind, name: String) -> UIImage? {
        image(for: icon(kind: kind, name: name))
    }

    @MainActor
    private static func image(for icon: Icon) -> UIImage? {
        if let hit = iconCache[icon] {
            return hit
        }
        let image: UIImage? = switch icon {
        case let .artwork(name):
            UIImage(named: "FileIcons/\(name)")?.withRenderingMode(.alwaysOriginal)
        case let .symbol(name):
            UIImage(systemName: name, withConfiguration: symbolConfiguration)?
                .withRenderingMode(.alwaysTemplate)
        }
        if let image {
            iconCache[icon] = image
        }
        return image
    }

    /// The same icon at the size the properties page shows it. A separate
    /// asset rather than the row's 40pt bitmap scaled up, which is a blur.
    /// Not cached: one page shows one of them.
    @MainActor
    static func largeImage(for node: FileNode) -> UIImage? {
        switch icon(for: node) {
        case let .artwork(name):
            UIImage(named: "FileIcons/\(name)-large")?.withRenderingMode(.alwaysOriginal)
        case let .symbol(name):
            UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: largeSide / 2, weight: .regular)
            )?.withRenderingMode(.alwaysTemplate)
        }
    }

    /// The side of the large artwork, in points; `Scripts/make-file-icons.swift`
    /// renders to the same number.
    static let largeSide: CGFloat = 192

    /// The point size a symbol is drawn at so it sits beside 40pt artwork
    /// without looking like a different list.
    @MainActor
    private static let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)

    @MainActor
    private static var iconCache: [Icon: UIImage] = [:]

    /// What the kind sort orders by. The extension, because that is what
    /// actually groups files a user recognises; the kind label would put every
    /// extensionless binary in one bucket named "File".
    static func sortKind(for node: FileNode) -> String {
        (node.name as NSString).pathExtension.lowercased()
    }

    /// Empty for a directory. `st_size` on a directory is the directory's own
    /// size and means nothing to anybody, and the honest size of its contents
    /// is a recursive walk — so the row says nothing rather than printing a
    /// placeholder that reads as a failure.
    ///
    /// Empty for a symlink too, and for the same reason: `lstat` reports the
    /// length of the target *string*, so `/var` reads as "11 bytes" — a number
    /// that is true, useless, and looks like the size of what it points at.
    static func sizeLabel(for node: FileNode) -> String {
        switch node.kind {
        case .directory, .symbolicLink: ""
        default: byteLabel(node.size)
        }
    }

    /// Off the main actor as well as on it: a size is also formatted while
    /// parsing — a Mach-O's encrypted segment, a "this file is too large"
    /// message — and those run on a background task. `ByteCountFormatter`'s
    /// class method rather than a shared instance, because a shared `Formatter`
    /// touched from two tasks is a data race for no gain.
    ///
    /// `.file` and not a preference: iOS spells sizes one way everywhere, and
    /// a file manager that spells them the other way is the odd one out on the
    /// device rather than the correct one.
    static func byteLabel(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Empty rather than a placeholder when the timestamp is zero, for the same
    /// reason as `sizeLabel`.
    ///
    /// A date/time *style* and never a format string: the order of the fields,
    /// the separators and the era are all the locale's business, and a format
    /// string spells `2026/8/13` in a language that writes `2026年8月13日`.
    static func dateLabel(_ epochSeconds: Double) -> String {
        guard epochSeconds > 0 else { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    /// Cached, and deliberately so: a list cell is configured on every scroll
    /// tick and building a `DateFormatter` costs more than everything else the
    /// cell does put together.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
