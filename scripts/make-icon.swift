// Renders the app icon (the menu bar glyph: a ring with a dot) into an .icns.
// Usage: swift scripts/make-icon.swift Loupe/Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size, flipped: false) { rect in
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let bg = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.height * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.21, blue: 0.25, alpha: 1),
                   ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1))!.draw(in: bg, angle: -90)
        let orange = NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.16, alpha: 1)
        let w = rect.width, h = rect.height
        // baseline
        orange.withAlphaComponent(0.35).setStroke()
        let base = NSBezierPath()
        base.lineWidth = w * 0.02
        base.move(to: NSPoint(x: w * 0.16, y: h * 0.42))
        base.line(to: NSPoint(x: w * 0.84, y: h * 0.42))
        base.stroke()
        // pulse
        let p = NSBezierPath()
        p.lineWidth = w * 0.055
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        let pts: [(CGFloat, CGFloat)] = [(0.16, 0.42), (0.30, 0.42), (0.36, 0.50), (0.42, 0.42), (0.48, 0.42), (0.54, 0.76), (0.60, 0.24), (0.66, 0.42), (0.72, 0.42), (0.76, 0.48), (0.84, 0.42)]
        for (i, pt) in pts.enumerated() {
            let point = NSPoint(x: w * pt.0, y: h * pt.1)
            if i == 0 { p.move(to: point) } else { p.line(to: point) }
        }
        orange.setStroke()
        p.stroke()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
