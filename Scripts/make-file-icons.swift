#!/usr/bin/env swift
// Regenerates the file-type artwork in `Fila/Resources/Assets.xcassets/FileIcons`.
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
// under `Scripts/Artwork`. Shipping them inside the deb is
// redistribution of Apple artwork, done deliberately — the alternative was a
// list of monochrome glyphs that all read the same at a glance.
//
// A type whose composed icon is a blank page (`public.database`,
// `public.symlink`) is deliberately absent: a database draws as the generic
// `document`, and a symlink draws its target with the `alias` arrow over it.
// No file is ever drawn with an SF Symbol — a glyph among pictures reads as a
// control — so anything `FilePresentation` pictures has an entry here.

import AppKit
import UniformTypeIdentifiers

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = repository.appendingPathComponent("Fila/Resources/Assets.xcassets/FileIcons")
let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

/// 40 points, the row's icon size, and 192 for the properties page's preview
/// as `<name>-large`. Ceilings as well as targets: the source art is 1024px,
/// and shipping that to draw a 40pt square costs megabytes and a decode.
/// `FilePresentation.largeSide` is the second number.
let sizes: [(suffix: String, points: CGFloat)] = [("", 40), ("-large", 192)]

enum Source {
    case bundled(String)
    case composed(String)
    case imported(String)
}

let icons: [(name: String, source: Source)] = [
    ("folder", .bundled("GenericFolderIcon")),
    ("drive-internal", .imported("磁盘-内置-Internal.png")),
    ("document", .bundled("GenericDocumentIcon")),
    ("application", .bundled("GenericApplicationIcon")),
    // The sidebar's presets: the root, the bootstrap, the camera roll, the
    // iTunes library, the mobile home, the inbox files are shared into, the trash.
    ("finder", .bundled("FinderIcon")),
    ("bootstrap", .bundled("SmartFolderIcon")),
    ("pictures", .bundled("PicturesFolderIcon")),
    ("music", .bundled("MusicFolderIcon")),
    ("home", .bundled("HomeFolderIcon")),
    ("inbox", .bundled("PublicFolderIcon")),
    ("trash", .bundled("FullTrashIcon")),
    // A saved server — an SMB share today, an FTP root later: the same
    // shared-folder picture Finder draws for a mounted share, so every
    // sidebar row is a picture and none is a symbol.
    ("shared-folder", .bundled("GenericSharepoint")),
    // Bundles and files the composed icon says nothing about, but CoreTypes
    // has a picture for: kernel extensions and frameworks, crash and panic
    // reports, fonts.
    ("kext", .bundled("KEXT")),
    ("report", .bundled("ProblemReport")),
    ("font", .bundled("ProfileFont")),
    // Finder's alias arrow, drawn over the whole icon: the artwork already
    // sits in the bottom-left corner of a full canvas, so it overlays at icon
    // size rather than as a small badge.
    ("alias", .bundled("AliasBadgeIcon")),
    // A fifo, a socket or a device node: Finder's gear. `UnknownFSObjectIcon`
    // is the literal match, but it is a faint dashed outline that all but
    // vanishes on a light row.
    ("special", .bundled("ToolbarAdvanced")),
    // A link whose target does not exist: "there is nothing there".
    ("broken-link", .bundled("GenericQuestionMarkIcon")),
    // The corner mark on a favourite folder in the sidebar.
    ("favorite", .bundled("FavoriteItemsIcon")),
    ("plist", .composed("com.apple.property-list")),
    ("image", .composed("public.image")),
    ("text", .composed("public.plain-text")),
    ("archive", .composed("public.zip-archive")),
    ("audio", .composed("public.audio")),
    ("video", .composed("public.movie")),
    ("pdf", .composed("com.adobe.pdf")),
    ("executable", .composed("public.unix-executable")),
]

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
        bitsPerPixel: 0
    ) else { return nil }
    bitmap.size = NSSize(width: points, height: points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let requestedIcons = Set(CommandLine.arguments.dropFirst())
for (name, source) in icons where requestedIcons.isEmpty || requestedIcons.contains(name) {
    let image: NSImage? = switch source {
    case let .bundled(file): NSImage(contentsOfFile: coreTypes + file + ".icns")
    case let .composed(identifier): UTType(identifier).map(NSWorkspace.shared.icon(for:))
    case let .imported(file): NSImage(contentsOf: repository.appendingPathComponent("Scripts/Artwork/\(file)"))
    }
    guard let image else {
        FileHandle.standardError.write(Data("no artwork for \(name)\n".utf8))
        exit(1)
    }

    for (suffix, points) in sizes {
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
