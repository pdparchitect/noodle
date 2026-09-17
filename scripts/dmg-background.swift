import AppKit

// Build-only renderer: no application, window, or Dock entry.
// A two-resolution TIFF keeps the chevron sharp on Retina displays.
guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--suite") else {
    fputs("Usage: dmg-background.swift OUTPUT.tiff [--suite]\n", stderr)
    exit(1)
}
let suite = CommandLine.arguments.count == 3
let size = suite ? NSSize(width: 900, height: 560) : NSSize(width: 660, height: 400)
let arrow = suite ? NSPoint(x: 570, y: 290) : NSPoint(x: 330, y: 200)
let representations: [NSBitmapImageRep] = [1, 2].map { scale in
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(scale))
    (transform as NSAffineTransform).concat()
    NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 245 / 255, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: arrow.x - 8, y: arrow.y + 17))
    chevron.line(to: NSPoint(x: arrow.x + 9, y: arrow.y))
    chevron.line(to: NSPoint(x: arrow.x - 8, y: arrow.y - 17))
    chevron.lineWidth = 6
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.black.setStroke()
    chevron.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
let data = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
