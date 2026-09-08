#!/usr/bin/env swift
// Renders the app icon as a small mark, light and dark, into
// `Fila/Resources/Assets.xcassets/AppIconMark.imageset`.
//
// Run on a Mac, by hand, when `Fila/Resources/AppIcon.icon` changes:
//
//     swift Scripts/make-app-mark.swift
//
// The `.icon` document is Icon Composer's; iOS composes the real app icon from
// it at install time and nothing else can ask for that rendering. The alert
// card and the web page want the same picture as a plain PNG, so this draws
// the document's one group — a fill and an image layer — the way Icon Composer
// does for a flat export: light keeps the document's fill, dark swaps it for
// the system's dark icon ground. Output is checked in; `WebUI`'s sync script
// copies it from the asset catalogue.

import AppKit

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let document = repository.appendingPathComponent("Fila/Resources/AppIcon.icon")
let output = repository.appendingPathComponent("Fila/Resources/Assets.xcassets/AppIconMark.imageset")

struct Layer {
    var image: NSImage
    var scale: CGFloat
    var translation: CGPoint // in points on the 1024-point canvas
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func srgb(_ text: String) -> NSColor {
    // "srgb:1.00000,1.00000,1.00000,1.00000"
    let parts = text.split(separator: ":").last?.split(separator: ",").compactMap { Double($0) } ?? []
    guard parts.count == 4 else { fail("unreadable fill: \(text)") }
    return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
}

let json = try JSONSerialization.jsonObject(
    with: Data(contentsOf: document.appendingPathComponent("icon.json"))
) as? [String: Any] ?? [:]
let fill = (json["fill"] as? [String: Any])?["automatic-gradient"] as? String ?? "srgb:1,1,1,1"
guard let group = (json["groups"] as? [[String: Any]])?.first,
      let layerInfo = (group["layers"] as? [[String: Any]])?.first,
      let imageName = layerInfo["image-name"] as? String,
      let image = NSImage(contentsOf: document.appendingPathComponent("Assets/\(imageName)"))
else { fail("icon.json has no image layer") }
let position = layerInfo["position"] as? [String: Any] ?? [:]
let translation = (position["translation-in-points"] as? [Double]) ?? [0, 0]
let layer = Layer(
    image: image,
    scale: CGFloat(position["scale"] as? Double ?? 1),
    translation: CGPoint(x: translation[0], y: translation[1])
)

/// One square PNG. `dark` swaps the document fill for the dark icon ground.
func render(side: Int, dark: Bool) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(side)
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)
    // iOS icon corner: 22.37% of the side, continuous in the real thing.
    let shape = NSBezierPath(roundedRect: canvas, xRadius: s * 0.2237, yRadius: s * 0.2237)
    shape.addClip()
    if dark {
        NSGradient(
            starting: NSColor(srgbRed: 0.18, green: 0.18, blue: 0.19, alpha: 1),
            ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        )?
            .draw(in: canvas, angle: -90)
    } else {
        srgb(fill).setFill()
        canvas.fill()
    }
    let inset = s * (1 - layer.scale) / 2
    // Icon Composer's y grows downward; AppKit's grows upward.
    let offset = CGPoint(x: layer.translation.x / 1024 * s, y: -layer.translation.y / 1024 * s)
    let frame = NSRect(x: inset + offset.x, y: inset + offset.y, width: s * layer.scale, height: s * layer.scale)
    layer.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    return bitmap.representation(using: .png, properties: [:])
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var manifest: [[String: Any]] = []
// 64 points is the alert card's image height; the web page scales down from @2x.
for (appearance, dark) in [("light", false), ("dark", true)] {
    for scale in [1, 2, 3] {
        let file = "mark-\(appearance)@\(scale)x.png"
        guard let data = render(side: 64 * scale, dark: dark) else { fail("render failed") }
        try data.write(to: output.appendingPathComponent(file))
        var entry: [String: Any] = ["idiom": "universal", "scale": "\(scale)x", "filename": file]
        if dark {
            entry["appearances"] = [["appearance": "luminosity", "value": "dark"]]
        }
        manifest.append(entry)
        print(file)
    }
}

let contents: [String: Any] = ["images": manifest, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
