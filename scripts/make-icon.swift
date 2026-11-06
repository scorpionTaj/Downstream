// Draws Downstream's app icon and writes Support/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (then commit Support/AppIcon.icns)
//
// Design: a rounded square in deep teal-to-blue, three flowing "stream" lines,
// and a bold white arrow pointing down into them.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Downstream.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024  // design on a 1024 grid

    // Body: Apple's grid keeps the shape 100pt in from each edge.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.55, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.28, blue: 0.70, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Stream: three waves, fading towards the bottom.
    for (index, y) in [330.0, 255.0, 180.0].enumerated() {
        let wave = NSBezierPath()
        wave.lineWidth = 34 * s
        wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: 210 * s, y: y * s))
        wave.curve(to: NSPoint(x: 512 * s, y: y * s),
                   controlPoint1: NSPoint(x: 310 * s, y: (y + 55) * s), controlPoint2: NSPoint(x: 412 * s, y: (y - 55) * s))
        wave.curve(to: NSPoint(x: 814 * s, y: y * s),
                   controlPoint1: NSPoint(x: 612 * s, y: (y + 55) * s), controlPoint2: NSPoint(x: 714 * s, y: (y - 55) * s))
        NSColor(white: 1, alpha: 0.85 - CGFloat(index) * 0.25).setStroke()
        wave.stroke()
    }

    // Arrow: shaft and head as one rounded shape.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 452 * s, y: 800 * s))
    arrow.line(to: NSPoint(x: 572 * s, y: 800 * s))
    arrow.line(to: NSPoint(x: 572 * s, y: 560 * s))
    arrow.line(to: NSPoint(x: 680 * s, y: 560 * s))
    arrow.line(to: NSPoint(x: 512 * s, y: 395 * s))
    arrow.line(to: NSPoint(x: 344 * s, y: 560 * s))
    arrow.line(to: NSPoint(x: 452 * s, y: 560 * s))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 24 * s
    NSColor.white.setFill()
    NSColor.white.setStroke()
    arrow.fill()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The sizes iconutil expects: 16–512 at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: base * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Support/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Support/AppIcon-1024.png"))
print("Wrote \(output.path)")
