import FilaFormats
import FilaProtocol
import Foundation
import UIKit
import UniformTypeIdentifiers

/// How a node reads in a list: its icon, its kind, its size and its date.
///
/// The initial icon comes from the name and the `lstat` alone.
enum FilePresentation {
    /// Which picture a row draws: full colour, never tinted.
    ///
    /// There is no SF Symbol case, on purpose. A file, a folder, an archive
    /// entry or an app is always drawn with a picture: a glyph among pictures
    /// reads as a control.
    enum Icon: Hashable {
        /// A name under `Assets.xcassets/FileIcons`: a folder, a bundle, a
        /// file type the Mac has a picture of, a sidebar place, a badge.
        case artwork(String)
        /// A file type no artwork matches, by lowercased extension (empty
        /// for none), drawn by the device — see `DeviceIcons`.
        case device(String)
    }

    static func format(of node: FileNode) -> FileFormat {
        FileFormat.detect(head: Data(), name: node.name)
    }

    /// The picture for a node, from its name and kind alone.
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
            return .artwork("broken-link")
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
        // By name alone: permissions do not identify content, since new user
        // files default to 0777, and a Mach-O without an extension is found
        // by `FilePresentation.picture`.
        switch FileFormat.detect(name: name) {
        case .propertyList: return .artwork("plist")
        case .machO: return .artwork("executable")
        case .archive: return .artwork("archive")
        case .image: return .artwork("image")
        case .audio: return .artwork("audio")
        case .video: return .artwork("video")
        case .pdf: return .artwork("pdf")
        case .text: return .artwork("text")
        case .sqlite, .binary, nil:
            // No artwork matches, so the device draws the type. An
            // extension the OS declares no type for draws what no
            // extension draws, so `backup.1 … backup.99999` is one
            // picture to make and keep, not a hundred thousand.
            let declared = UTType(filenameExtension: ext).map { !$0.isDynamic } ?? false
            return .device(declared ? ext : "")
        }
    }

    /// The icon as a drawable image, at the size a row draws it.
    ///
    /// Cached, because this is called once per cell per scroll tick and a
    /// directory can hold 100k of them: `artworkCache` keeps the app's own
    /// pictures and `DeviceIcons` the OS's. A listing draws from a few dozen
    /// distinct pictures no matter how long it is, so there is nothing to evict.
    @MainActor
    static func image(for node: FileNode) -> UIImage? {
        image(for: icon(for: node))
    }

    @MainActor
    static func image(kind: FileKind, name: String) -> UIImage? {
        image(for: icon(kind: kind, name: name))
    }

    /// A picture named outright, for one that is not a node's: a folder
    /// behind a tab, a clipboard entry that no longer exists.
    @MainActor
    static func image(for icon: Icon) -> UIImage? {
        switch icon {
        case let .device(type):
            return DeviceIcons.image(for: type)
        case let .artwork(name):
            if let hit = artworkCache[name] {
                return hit
            }
            // `UIImage(named:)` caches the bitmap; this skips the
            // rendering-mode copy, which it does not.
            let image = UIImage(named: "FileIcons/\(name)")?.withRenderingMode(.alwaysOriginal)
            artworkCache[name] = image
            return image
        }
    }

    /// The picture at the properties page's size: the artwork's `-large` set
    /// rather than the row's bitmap scaled up, which is a blur. The device's
    /// is the cached one; `DeviceIcons.largeImage` resolves a sharper one.
    @MainActor
    static func largeImage(for icon: Icon) -> UIImage? {
        switch icon {
        case let .device(type): DeviceIcons.image(for: type)
        case let .artwork(name): UIImage(named: "FileIcons/\(name)-large")?.withRenderingMode(.alwaysOriginal)
        }
    }

    /// The side of the properties page's picture, in points;
    /// `Scripts/make-file-icons.swift` renders `-large` to the same number.
    static let largeSide: CGFloat = 192

    @MainActor
    private static var artworkCache: [String: UIImage] = [:]

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
