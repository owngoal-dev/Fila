#!/usr/bin/env swift
// Regenerates the artwork left in `Fila/Resources/Assets.xcassets/FileIcons`.
//
// Run on a Mac, by hand, when the icon set changes:
//
//     swift Scripts/make-file-icons.swift
//
// Pass asset names to regenerate only those icons, e.g. `drive-internal`.
//
// Not wired into the Makefile: it needs AppKit and the running system's own
// icon artwork, so it cannot run on the build the app ships from, and the
// output is checked in.
//
// Files, folders, bundles and types are not here: the app draws the OS's own
// pictures of those at runtime (`DeviceIcons`), because shipping Apple's
// artwork inside the deb is redistributing it. What is left is what iOS has
// no picture of — the sidebar's places, the link and favourite badges — and
// every one of those is still Apple's: bundled icons come from
// `CoreTypes.bundle`, and imported artwork is retained under `Scripts/Artwork`.
// Each is a candidate for replacement, not a precedent; see the picture rules
// in AGENTS.md before adding one.

import AppKit

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = repository.appendingPathComponent("Fila/Resources/Assets.xcassets/FileIcons")
let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

/// 40 points, the row's icon size; `-large` is 192, the empty trash's status
/// card. Ceilings as well as targets: the source art is 1024px, and shipping
/// that to draw a 40pt square costs megabytes and a decode.
let rowSize: (suffix: String, points: CGFloat) = ("", 40)
let largeSize: (suffix: String, points: CGFloat) = ("-large", 192)

enum Source {
    case bundled(String)
    case imported(String)
}

let icons: [(name: String, source: Source, large: Bool)] = [
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
    // A saved server — an SMB share today, an FTP root later: the same
    // shared-folder picture Finder draws for a mounted share, so every
    // sidebar row is a picture and none is a symbol.
    ("shared-folder", .bundled("GenericSharepoint"), false),
    // Finder's alias arrow, drawn over the whole icon: the artwork already
    // sits in the bottom-left corner of a full canvas, so it overlays at icon
    // size rather than as a small badge.
    ("alias", .bundled("AliasBadgeIcon"), false),
    // The corner mark on a favourite folder in the sidebar.
    ("favorite", .bundled("FavoriteItemsIcon"), false),
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
    case let .imported(file): NSImage(contentsOf: repository.appendingPathComponent("Scripts/Artwork/\(file)"))
    }
    guard let image else {
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
