// Draws AppIcon.icns: two windows pushed off to the sides, wallpaper showing
// between them, on a round plate on the MackEye Apps tartan (2026-09-26). Run
// from the project root after changing the look:
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

/// The MackEye Apps tartan, the cloth of the brand's logo (~/MackEye/brand/make-logo.py):
/// a coral ground with black pinstripes, and a pistachio band edged in black around a
/// white stripe, crossing low and to the left. All solid. The pinstripes go down first
/// and the bands on top, each drawn from the outside in (both greens, both blacks, both
/// whites), so no stripe edge lets the coral show through and the whites cross as a +.
/// The numbers are the logo's: threads of its sett, 3px each in its 512px.
func drawMackEyeTartan(in rect: NSRect) {
    let colours: [Character: NSColor] = [
        "G": NSColor(srgbRed: 0.925, green: 0.467, blue: 0.373, alpha: 1),  // coral #EC775F
        "B": NSColor(srgbRed: 0.678, green: 0.788, blue: 0.541, alpha: 1),  // pistachio #ADC98A
        "P": NSColor(srgbRed: 0.122, green: 0.118, blue: 0.106, alpha: 1),  // black #1F1E1B
        "H": NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1),  // white #FAF9F5
    ]
    // Half the sett, from the middle of the coral to the middle of the band.
    let half: [(key: Character, threads: CGFloat)] =
        [("G", 30), ("P", 3), ("G", 4), ("P", 3), ("G", 24), ("B", 16), ("P", 2), ("H", 18)]
    let full = half + half.dropFirst().dropLast().reversed()
    let firstBand = half.firstIndex { $0.key == "B" }!
    let inBand = half.indices.map { $0 >= firstBand } + (1..<half.count - 1).reversed().map { $0 >= firstBand }
    let band = Array(half[firstBand...])
    let unit = rect.width * 3 / 512
    let period = full.reduce(0) { $0 + $1.threads } * unit
    let bandMiddle = (half.dropLast().reduce(0) { $0 + $1.threads } + half.last!.threads / 2) * unit
    let halves = band.indices.map { k in
        (band[k..<band.count - 1].reduce(0) { $0 + $1.threads } + band.last!.threads / 2) * unit
    }
    let cross = NSPoint(x: rect.minX + rect.width * 182 / 512, y: rect.minY + rect.width * 182 / 512)

    colours["G"]!.setFill()
    rect.fill()
    var layers = Array(repeating: [NSRect](), count: band.count)
    for vertical in [true, false] {
        let (lo, hi) = vertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
        func strip(_ from: CGFloat, _ width: CGFloat) -> NSRect {
            vertical ? NSRect(x: from, y: rect.minY, width: width, height: rect.height)
                     : NSRect(x: rect.minX, y: from, width: rect.width, height: width)
        }
        var start = (vertical ? cross.x : cross.y) - bandMiddle
        while start > lo { start -= period }
        var pos = start
        while pos < hi {
            for (i, stripe) in full.enumerated() {
                let width = stripe.threads * unit
                if stripe.key != "G" && !inBand[i] && pos < hi && pos + width > lo {
                    colours[stripe.key]!.setFill()
                    strip(pos, width).fill()
                }
                pos += width
            }
        }
        var middle = start + bandMiddle - period
        while middle - halves[0] < hi {
            for (k, h) in halves.enumerated() where middle + h > lo && middle - h < hi {
                layers[k].append(strip(middle - h, 2 * h))
            }
            middle += period
        }
    }
    for (k, stripe) in band.enumerated() {
        colours[stripe.key]!.setFill()
        layers[k].forEach { $0.fill() }
    }
}

/// A round plate in the app's own colours for the art to sit on, with a soft shadow
/// that lifts it off the tartan.
func drawPlate(_ plate: NSBezierPath, gradient: NSGradient, size s: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.shadowColor = NSColor(srgbRed: 0.122, green: 0.118, blue: 0.106, alpha: 0.35)
    shadow.set()
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)  // the shadow falls from the plate as one shape
    gradient.draw(in: plate, angle: -90)
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

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

    // The MackEye tartan fills the icon, and the app sits on a round plate in the
    // middle (Adam picked this, "8", from 20 options on 2026-09-26).
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    drawMackEyeTartan(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    let r = rect.width * 0.37
    let box = NSRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r)
    let plate = NSBezierPath(ovalIn: box)

    // The wallpaper you're revealing.
    drawPlate(plate, gradient: NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.56, blue: 0.98, alpha: 1),
                                          ending: NSColor(srgbRed: 0.07, green: 0.20, blue: 0.62, alpha: 1))!,
              size: s)

    // Windows slid off each edge, clipped by the plate so they stay inside it.
    NSGraphicsContext.saveGraphicsState()
    plate.setClip()
    let windowWidth = box.width * 0.60
    let windowHeight = box.height * 0.54
    let windowY = box.midY - windowHeight / 2
    let windowRadius = windowWidth * 0.11
    for x in [box.minX - windowWidth * 0.62, box.maxX - windowWidth * 0.38] {
        let frame = NSRect(x: x, y: windowY, width: windowWidth, height: windowHeight)
        let window = NSBezierPath(roundedRect: frame, xRadius: windowRadius, yRadius: windowRadius)
        NSColor(white: 1, alpha: 0.97).setFill()
        window.fill()
        // A title bar, so it reads as a window and not a blank card.
        let bar = NSRect(x: frame.minX, y: frame.maxY - windowHeight * 0.17,
                         width: frame.width, height: windowHeight * 0.17)
        NSGraphicsContext.saveGraphicsState()
        window.addClip()  // intersects the plate clip; setClip would replace it
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
