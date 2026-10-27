//
//  make-icon.swift
//  Renders AppIcon.icns for DimBar: a golden sun on a dark rounded square.
//
//  usage: swift tools/make-icon.swift <output.iconset dir>
//

import AppKit
import Foundation

let canvas = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

func bitmap(_ side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)
    return rep
}

/// Draws the 1024×1024 master icon.
func renderMaster() -> NSBitmapImageRep {
    let rep = bitmap(canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded tile.
    let tile = NSRect(x: 64, y: 64, width: 896, height: 896)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 200, yRadius: 200)
    NSGradient(colors: [color(0x33333A), color(0x131316)])?.draw(in: squircle, angle: -90)

    // Glassy top highlight.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.12), NSColor(white: 1, alpha: 0.0)])?
        .draw(in: NSRect(x: 64, y: 640, width: 896, height: 320), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Sun glyph.
    if let base = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color(0xFFC53D)]))
        if let symbol = base.withSymbolConfiguration(configuration) {
            let side = CGFloat(canvas) * 0.58
            let target = NSRect(x: (CGFloat(canvas) - side) / 2,
                                y: (CGFloat(canvas) - side) / 2,
                                width: side, height: side)
            symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Scales the master down to `pixels` and writes a PNG.
func writePNG(master: NSBitmapImageRep, pixels: Int, to url: URL) {
    let rep = bitmap(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    let copy = master.copy() as! NSBitmapImageRep
    copy.size = NSSize(width: canvas, height: canvas)
    image.addRepresentation(copy)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: swift tools/make-icon.swift <output.iconset dir>")
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let master = renderMaster()
let variants: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let name = variant.scale == 1
        ? "icon_\(variant.size)x\(variant.size).png"
        : "icon_\(variant.size)x\(variant.size)@2x.png"
    writePNG(master: master, pixels: variant.size * variant.scale,
             to: output.appendingPathComponent(name))
}

writePNG(master: master, pixels: 1024, to: output.appendingPathComponent("icon_1024.png"))
print("wrote \(output.path)")
