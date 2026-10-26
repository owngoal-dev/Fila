#!/usr/bin/env swift
// Regenerates the artwork in `Fila/Resources/Assets.xcassets/FileIcons`.
//
// Run on a Mac, by hand, when the icon set changes:
//
//     swift Scripts/make-file-icons.swift
//     swift Scripts/remove-archive-label.swift
//
// The second step removes the ZIP label from the shared archive artwork:
// this icon also represents Debian packages, tarballs and other formats.
// Pass asset names to regenerate only those icons, e.g. `drive-internal`.
//
// Not wired into the Makefile: it needs AppKit and the running system's own
// icon artwork, so it cannot run on the build the app ships from, and the
// output is checked in.
//
// Every icon here is Apple's: bundled icons come from `CoreTypes.bundle`,
// composed icons come from `NSWorkspace`, and imported artwork is retained
// under `Scripts/Artwork`. Shipping them inside the deb is redistribution of
// Apple artwork, done deliberately: the pictures QuickLook draws on the
// device are low-resolution, and a blank tile for an app. A file type with no
// entry here is drawn by the device (`DeviceIcons`).

import AppKit
import UniformTypeIdentifiers

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = repository.appendingPathComponent("Fila/Resources/Assets.xcassets/FileIcons")
let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

/// 64 points, the grid's icon size, which a row scales down; `-large` is 192,
/// the properties page's picture (`FilePresentation.largeSide`) and the empty
/// trash's status card. Ceilings as well as targets: the source art is 1024px,
/// and shipping that to draw a 64pt square costs megabytes and a decode.
let rowSize: (suffix: String, points: CGFloat) = ("", 64)
let largeSize: (suffix: String, points: CGFloat) = ("-large", 192)

enum Source {
    case bundled(String)
    /// An `.icns` corner badge — Finder draws it inside a folder-sized canvas,
    /// so it is cropped to the mark before it is drawn.
    case badge(String)
    case composed(String)
    case imported(String)
}

let icons: [(name: String, source: Source, large: Bool)] = [
    // What `FilePresentation` pictures a node with; the properties page draws
    // each one large.
    ("folder", .bundled("GenericFolderIcon"), true),
    ("application", .bundled("GenericApplicationIcon"), true),
    // Bundles, files and nodes the composed icon says nothing about, but
    // CoreTypes has a picture for: kernel extensions and frameworks, crash
    // and panic reports, fonts.
    ("kext", .bundled("KEXT"), true),
    ("report", .bundled("ProblemReport"), true),
    ("font", .bundled("ProfileFont"), true),
    // A fifo, a socket or a device node: Finder's gear. `UnknownFSObjectIcon`
    // is the literal match, but it is a faint dashed outline that all but
    // vanishes on a light row.
    ("special", .bundled("ToolbarAdvanced"), true),
    // A link whose target does not exist: "there is nothing there".
    ("broken-link", .bundled("GenericQuestionMarkIcon"), true),
    // A file whose type nothing declares — no extension, or one the OS has no
    // type for. The device's own generic icon is a blank tile on some systems,
    // which reads as a missing picture.
    ("document", .bundled("GenericDocumentIcon"), true),
    ("plist", .composed("com.apple.property-list"), true),
    ("image", .composed("public.image"), true),
    ("text", .composed("public.plain-text"), true),
    ("archive", .composed("public.zip-archive"), true),
    ("audio", .composed("public.audio"), true),
    ("video", .composed("public.movie"), true),
    ("pdf", .composed("com.adobe.pdf"), true),
    ("executable", .composed("public.unix-executable"), true),
    // The sidebar's presets: the root, the bootstrap, the camera roll, the
    // iTunes library, the mobile home, the inbox files are shared into, the trash.
    ("drive-internal", .imported("磁盘-内置-Internal.png"), false),
    ("bootstrap", .bundled("SmartFolderIcon"), false),
    ("pictures", .bundled("PicturesFolderIcon"), false),
    ("music", .bundled("MusicFolderIcon"), false),
    ("home", .bundled("HomeFolderIcon"), false),
    ("inbox", .bundled("PublicFolderIcon"), false),
    ("trash", .bundled("FullTrashIcon"), false),
    ("trash-empty", .bundled("TrashIcon"), true),
    // Finder's alias arrow, drawn over the whole icon: the artwork already
    // sits in the bottom-left corner of a full canvas, so it overlays at icon
    // size rather than as a small badge.
    ("alias", .bundled("AliasBadgeIcon"), false),
    // The corner mark on a favourite folder in the sidebar.
    ("favorite", .bundled("FavoriteItemsIcon"), false),
    // The corner mark on a volume that refuses writes — Finder's own
    // read-only badge, so the sidebar keeps to artwork.
    ("read-only", .badge("ReadOnlyFolderBadgeIcon"), false),
    // A saved server — an SMB share today, an FTP root later: the same
    // shared-folder picture Finder draws for a mounted share, so every
    // sidebar row is a picture and none is a symbol. macOS 27's CoreTypes no
    // longer has it, so the checked-in 40pt copy from macOS 26 stays.
    ("shared-folder", .bundled("GenericSharepoint"), false),
]

/// An `.icns` badge is drawn inside a folder-sized canvas, because Finder puts
/// it in a folder's corner at about a fifth of the icon. Used as a badge of its
/// own that canvas is mostly emptiness — measured, `ReadOnlyFolderBadgeIcon`
/// fills 21% of it — so the mark is cropped out and fills the frame instead.
func trimmed(_ image: NSImage) -> NSImage {
    guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
          let source = rep.cgImage
    else { return image }
    let width = source.width, height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return image }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0 ..< height {
        for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 12 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return image }
    let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let mark = source.cropping(to: box) else { return image }
    return NSImage(cgImage: mark, size: NSSize(width: box.width, height: box.height))
}

func render(_ image: NSImage, points: CGFloat, scale: Int) -> Data? {
    let pixels = Int(points) * scale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0,
    ) else { return nil }
    bitmap.size = NSSize(width: points, height: points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let size = image.size
    let side = min(points / max(size.width, 1), points / max(size.height, 1))
    let drawn = NSSize(width: size.width * side, height: size.height * side)
    image.draw(in: NSRect(
        x: (points - drawn.width) / 2,
        y: (points - drawn.height) / 2,
        width: drawn.width,
        height: drawn.height,
    ))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let requestedIcons = Set(CommandLine.arguments.dropFirst())
for (name, source, large) in icons where requestedIcons.isEmpty || requestedIcons.contains(name) {
    let image: NSImage? = switch source {
    case let .bundled(file): NSImage(contentsOfFile: coreTypes + file + ".icns")
    case let .badge(file): NSImage(contentsOfFile: coreTypes + file + ".icns").map(trimmed)
    case let .composed(identifier): UTType(identifier).map(NSWorkspace.shared.icon(for:))
    case let .imported(file): NSImage(contentsOf: repository.appendingPathComponent("Scripts/Artwork/\(file)"))
    }
    guard let image else {
        // A source a newer macOS dropped keeps the copy already checked in.
        if FileManager.default.fileExists(atPath: output.appendingPathComponent("\(name).imageset").path) {
            FileHandle.standardError.write(Data("no artwork for \(name); kept the checked-in copy\n".utf8))
            continue
        }
        FileHandle.standardError.write(Data("no artwork for \(name)\n".utf8))
        exit(1)
    }

    for (suffix, points) in large ? [rowSize, largeSize] : [rowSize] {
        let set = name + suffix
        let directory = output.appendingPathComponent("\(set).imageset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: String]] = []
        for scale in [1, 2, 3] {
            let file = "\(set)@\(scale)x.png"
            guard let data = render(image, points: points, scale: scale) else { exit(1) }
            try data.write(to: directory.appendingPathComponent(file))
            manifest.append(["idiom": "universal", "scale": "\(scale)x", "filename": file])
        }
        let contents: [String: Any] = ["images": manifest, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("Contents.json"))
        print(set)
    }
}
