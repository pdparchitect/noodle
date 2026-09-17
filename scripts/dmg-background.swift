import AppKit

// Build-only renderer: no application, window, or Dock entry.
// A two-resolution TIFF keeps the chevron sharp on Retina displays.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: dmg-background.swift OUTPUT.tiff\n", stderr)
    exit(1)
}
let size = NSSize(width: 660, height: 400)
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
    chevron.move(to: NSPoint(x: 322, y: 217))
    chevron.line(to: NSPoint(x: 339, y: 200))
    chevron.line(to: NSPoint(x: 322, y: 183))
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
