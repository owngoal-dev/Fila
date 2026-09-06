#!/usr/bin/env swift
// Run after make-file-icons.swift to keep the shared archive artwork format-neutral.
import AppKit

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icons = repository.appendingPathComponent("Fila/Resources/Assets.xcassets/FileIcons")

for (name, points) in [("archive", 40), ("archive-large", 192)] {
    for scale in 1...3 {
        let file = icons.appendingPathComponent("\(name).imageset/\(name)@\(scale)x.png")
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: file)),
              bitmap.pixelsWide == points * scale, bitmap.pixelsHigh == points * scale,
              bitmap.bitsPerSample == 8, !bitmap.isPlanar,
              let pixels = bitmap.bitmapData else {
            fatalError("Unexpected archive artwork: \(file.path)")
        }
        // The smallest representation already omits the label.
        guard bitmap.pixelsWide > 40 else { continue }
        let side = Double(bitmap.pixelsWide)
        let left = Int(floor(side * 0.40)), right = Int(ceil(side * 0.60))
        let top = Int(floor(side * 0.77)), bottom = Int(ceil(side * 0.88))
        // Bitmap coordinates start at the top-left. Reconstruct the paper
        // from the clean pixels just above and below the lettering, retaining
        // its gradient and leaving the zipper, edges and transparency intact.
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        for x in left...right {
            let upper = (top - 1) * bitmap.bytesPerRow + x * bytesPerPixel
            let lower = (bottom + 1) * bitmap.bytesPerRow + x * bytesPerPixel
            for y in top...bottom {
                let t = Double(y - top + 1) / Double(bottom - top + 2)
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                // Work in the source color space to avoid a visible patch
                // caused by converting the sampled colors through NSColor.
                for channel in 0..<bytesPerPixel {
                    let a = Double(pixels[upper + channel]), b = Double(pixels[lower + channel])
                    pixels[offset + channel] = UInt8((a + (b - a) * t).rounded())
                }
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode archive artwork: \(file.path)")
        }
        try png.write(to: file, options: .atomic)
        print(file.lastPathComponent)
    }
}
