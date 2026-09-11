import FilaFormats
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
    /// Which picture a row draws: a full-colour PNG out of the asset
    /// catalogue, never tinted.
    ///
    /// There is no SF Symbol case, on purpose. A file, a folder, an archive
    /// entry or an app is always drawn with artwork: a glyph among pictures
    /// reads as a control. A type the system has no picture for draws as the
    /// generic `document`.
    enum Icon: Hashable {
        /// A name under `Assets.xcassets/FileIcons`.
        case artwork(String)

        var name: String {
            switch self {
            case let .artwork(name): name
            }
        }
    }

    static func format(of node: FileNode) -> FileFormat {
        FileFormat.detect(head: Data(), name: node.name)
    }

    /// The artwork for a node, from its name and kind alone.
    ///
    /// Where the composed macOS icon is a blank sheet of paper — a SQLite
    /// database — the row draws the generic `document`: nothing more specific
    /// exists, and a glyph would be the one row drawn differently.
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
            return .artwork("broken-link")
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
            return .artwork("document")
        case .fifo, .socket, .blockDevice, .characterDevice:
            return .artwork("special")
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
        case .text: return .artwork("text")
        case .sqlite, .binary: return .artwork("document")
        }
    }

    /// The icon as a drawable image, at the size a row draws it.
    ///
    /// Cached, because this is called once per cell per scroll tick and a
    /// directory can hold 100k of them. The dictionary is the whole cache: a
    /// listing draws from at most a dozen distinct icons no matter how long it
    /// is, so there is nothing to evict and no cost in keeping them.
    /// `UIImage(named:)` has a cache of its own behind it; the point of this
    /// one is to skip the rendering-mode copy, which `UIImage` does not cache.
    @MainActor
    static func image(for node: FileNode) -> UIImage? {
        image(for: icon(for: node))
    }

    @MainActor
    static func image(kind: FileKind, name: String) -> UIImage? {
        image(for: icon(kind: kind, name: name))
    }

    /// Artwork named outright, for a picture that is not a node's: a folder
    /// behind a tab, a clipboard entry that no longer exists.
    @MainActor
    static func image(for icon: Icon) -> UIImage? {
        if let hit = iconCache[icon] {
            return hit
        }
        guard let image = UIImage(named: "FileIcons/\(icon.name)")?.withRenderingMode(.alwaysOriginal) else {
            return nil
        }
        iconCache[icon] = image
        return image
    }

    /// The same icon at the size the properties page shows it. A separate
    /// asset rather than the row's 40pt bitmap scaled up, which is a blur.
    /// Not cached: one page shows one of them.
    @MainActor
    static func largeImage(for node: FileNode) -> UIImage? {
        UIImage(named: "FileIcons/\(icon(for: node).name)-large")?.withRenderingMode(.alwaysOriginal)
    }

    /// The side of the large artwork, in points; `Scripts/make-file-icons.swift`
    /// renders to the same number.
    static let largeSide: CGFloat = 192

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
