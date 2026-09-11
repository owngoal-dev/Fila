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
    // A saved server — an SMB share today, an FTP root later: the same
    // shared-folder picture Finder draws for a mounted share, so every
    // sidebar row is a picture and none is a symbol. macOS 27's CoreTypes no
    // longer has it, so the checked-in 40pt copy from macOS 26 stays.
    ("shared-folder", .bundled("GenericSharepoint"), false),
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
for (name, source, large) in icons where requestedIcons.isEmpty || requestedIcons.contains(name) {
    let image: NSImage? = switch source {
    case let .bundled(file): NSImage(contentsOfFile: coreTypes + file + ".icns")
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
