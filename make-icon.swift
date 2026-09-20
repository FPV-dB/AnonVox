import AppKit

let master: CGFloat = 1024

func drawIcon(into size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / master, y: size / master)
    NSGraphicsContext.current!.imageInterpolation = .high

    // ---- rounded-square background with a vertical gradient ----
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                             xRadius: 185, yRadius: 185)
    let backdrop = NSGradient(colors: [
        NSColor(calibratedRed: 0.42, green: 0.38, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.11, blue: 0.40, alpha: 1)
    ])!
    backdrop.draw(in: plate, angle: -90)

    // ---- microphone, offset left to leave room for the badge ----
    let cx: CGFloat = 424
    NSColor.white.setFill()
    NSColor.white.setStroke()

    // capsule body
    NSBezierPath(roundedRect: NSRect(x: cx - 100, y: 536, width: 200, height: 310),
                 xRadius: 100, yRadius: 100).fill()

    // cradle: an open arc under the body
    let cradle = NSBezierPath()
    cradle.appendArc(withCenter: NSPoint(x: cx, y: 568), radius: 168,
                     startAngle: 204, endAngle: 336)
    cradle.lineWidth = 48
    cradle.lineCapStyle = .round
    cradle.stroke()

    // stem + base
    NSBezierPath(roundedRect: NSRect(x: cx - 24, y: 300, width: 48, height: 100),
                 xRadius: 24, yRadius: 24).fill()
    NSBezierPath(roundedRect: NSRect(x: cx - 100, y: 268, width: 200, height: 48),
                 xRadius: 24, yRadius: 24).fill()

    // ---- question-mark badge, bottom right ----
    let badge = NSPoint(x: 738, y: 322)
    // dark separation ring so the badge reads against the mic base
    NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.32, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: badge.x - 182, y: badge.y - 182, width: 364, height: 364)).fill()

    let disc = NSBezierPath(ovalIn: NSRect(x: badge.x - 152, y: badge.y - 152, width: 304, height: 304))
    NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.16, alpha: 1)
    ])!.draw(in: disc, angle: -90)

    let mark = "?" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 250, weight: .heavy),
        .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.32, alpha: 1)
    ]
    let textSize = mark.size(withAttributes: attrs)
    mark.draw(at: NSPoint(x: badge.x - textSize.width / 2,
                          y: badge.y - textSize.height / 2 - 6),
              withAttributes: attrs)

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .calibratedRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: "/Users/m/Documents/AnonVox/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    writePNG(drawIcon(into: CGFloat(px)), pixels: px, to: out.appendingPathComponent("\(name).png"))
}
// a standalone preview to eyeball
writePNG(drawIcon(into: 512), pixels: 512, to: URL(fileURLWithPath: "/tmp/icon_preview.png"))
print("rendered \(variants.count) sizes")
