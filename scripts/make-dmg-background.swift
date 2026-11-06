// Draws the DMG window background (660×400 pt, plus a 2× version) and writes Support/dmg/background.tiff.
// Usage: swift scripts/make-dmg-background.swift
//
// Layout matches Support/dmg/settings.py: the app icon sits at (170, 205), Applications at (490, 205).
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Support/dmg")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let width: CGFloat = 660, height: CGFloat = 400

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)  // points, so Finder knows which one is @2x
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)

    // Soft sunset: peach → pink → lavender, light enough for Finder's dark icon labels.
    NSGradient(colors: [color(1.00, 0.86, 0.72), color(0.99, 0.78, 0.84), color(0.86, 0.80, 0.99)])!
        .draw(in: bounds, angle: -20)

    // Glow behind each icon spot.
    for x in [170.0, 490.0] {
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.75), NSColor.white.withAlphaComponent(0)])!
        glow.draw(fromCenter: NSPoint(x: x, y: height - 205), radius: 0, toCenter: NSPoint(x: x, y: height - 205), radius: 105,
                  options: [])
    }

    // Three gentle waves along the bottom, echoing the icon.
    for (index, base) in [70.0, 48.0, 26.0].enumerated() {
        let wave = NSBezierPath()
        wave.lineWidth = 6
        wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: -10, y: base))
        var x: CGFloat = -10
        while x < width + 10 {
            wave.curve(to: NSPoint(x: x + 110, y: base),
                       controlPoint1: NSPoint(x: x + 35, y: base + 12), controlPoint2: NSPoint(x: x + 75, y: base - 12))
            x += 110
        }
        color(0.96, 0.30, 0.52, 0.22 - CGFloat(index) * 0.05).setStroke()
        wave.stroke()
    }

    // Arrow from the app to Applications, in the icon's gradient.
    let arrow = NSBezierPath()
    let y = height - 205
    arrow.move(to: NSPoint(x: 262, y: y + 9))
    arrow.line(to: NSPoint(x: 372, y: y + 9))
    arrow.line(to: NSPoint(x: 372, y: y + 24))
    arrow.line(to: NSPoint(x: 405, y: y))
    arrow.line(to: NSPoint(x: 372, y: y - 24))
    arrow.line(to: NSPoint(x: 372, y: y - 9))
    arrow.line(to: NSPoint(x: 262, y: y - 9))
    arrow.close()
    arrow.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    arrow.addClip()
    NSGradient(colors: [color(1.00, 0.55, 0.25), color(0.96, 0.28, 0.50), color(0.56, 0.27, 0.98)])!
        .draw(in: arrow.bounds, angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // Title and instruction.
    let plum = color(0.30, 0.12, 0.32)
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: plum.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(in: NSRect(x: 0, y: y, width: width, height: size * 1.5))
    }
    // Both lines sit at the top: Finder's path and status bars (if the user shows them) cover the bottom.
    draw("Downstream", size: 26, weight: .bold, alpha: 0.9, y: height - 64)
    draw("Drag Downstream into Applications to install it", size: 13, weight: .medium, alpha: 0.7, y: height - 92)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let png1 = out.appendingPathComponent("background.png")
let png2 = out.appendingPathComponent("background@2x.png")
try render(scale: 1).representation(using: .png, properties: [:])!.write(to: png1)
try render(scale: 2).representation(using: .png, properties: [:])!.write(to: png2)

// One TIFF holding both resolutions: Finder picks the sharp one on Retina displays.
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", png1.path, png2.path, "-out", out.appendingPathComponent("background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
try? FileManager.default.removeItem(at: png1)
print("Wrote \(out.appendingPathComponent("background.tiff").path) and background@2x.png (preview)")
