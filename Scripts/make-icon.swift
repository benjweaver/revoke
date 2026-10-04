#!/usr/bin/env swift
// Renders the app icon into App/Assets.xcassets/AppIcon.appiconset.
//   swift Scripts/make-icon.swift
import AppKit

let outDir = "App/Assets.xcassets/AppIcon.appiconset"

/// Draws the icon on a 1024-point canvas: a warm red square with a white shielded
/// lock. `scale` is pixels per point: shadows ignore the context's transform, so the
/// shadow is sized by hand.
func draw(in ctx: CGContext, scale: CGFloat) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [NSColor(red: 1.00, green: 0.47, blue: 0.27, alpha: 1).cgColor,
                  NSColor(red: 0.80, green: 0.13, blue: 0.24, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    ctx.restoreGState()

    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
        // Palette layers: the lock, then the shield around it.
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.86, green: 0.22, blue: 0.25, alpha: 1), .white]))
    let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let size = symbol.size
    symbol.draw(in: CGRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height))
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(in: ctx, scale: scale)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = "icon_\(px).png"
    try render(pixels: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
let catalog: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
