// Draws AppIcon.icns: two windows pushed off to the sides, wallpaper showing
// between them. Run from the project root after changing the look:
//
//   swift tools/make-icon.swift
//
// build.sh copies the .icns into the bundle, so a rebuild is what applies it.

import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
let out = URL(fileURLWithPath: "AppIcon.icns")

// Every pixel size iconutil wants, and the names it expects for each.
let files: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

/// Exact pixel dimensions, so nothing gets rendered at the screen's 2x scale.
func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no bitmap at \(size)") }
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon art sits inside a margin rather than filling the canvas.
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // The wallpaper you're revealing.
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.56, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.20, blue: 0.62, alpha: 1))?
        .draw(in: squircle, angle: -90)

    // Windows slid off each edge, clipped by the squircle so they stay inside it.
    NSGraphicsContext.saveGraphicsState()
    squircle.setClip()
    let windowWidth = rect.width * 0.60
    let windowHeight = rect.height * 0.54
    let windowY = rect.midY - windowHeight / 2
    let windowRadius = windowWidth * 0.11
    for x in [rect.minX - windowWidth * 0.62, rect.maxX - windowWidth * 0.38] {
        let frame = NSRect(x: x, y: windowY, width: windowWidth, height: windowHeight)
        let window = NSBezierPath(roundedRect: frame, xRadius: windowRadius, yRadius: windowRadius)
        NSColor(white: 1, alpha: 0.97).setFill()
        window.fill()
        // A title bar, so it reads as a window and not a blank card.
        let bar = NSRect(x: frame.minX, y: frame.maxY - windowHeight * 0.17,
                         width: frame.width, height: windowHeight * 0.17)
        NSGraphicsContext.saveGraphicsState()
        window.addClip()  // intersects the squircle clip; setClip would replace it
        NSColor(white: 0.82, alpha: 1).setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("no png at \(size)")
    }
    return png
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (size, names) in files {
    let png = render(size: size)
    for name in names {
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(out.lastPathComponent) from \(files.values.joined().count) pngs")
