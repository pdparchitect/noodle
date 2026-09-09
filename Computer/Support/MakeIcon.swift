import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 195, yRadius: 195)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.38, blue: 0.77, alpha: 1),
                   ending: NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.90, alpha: 1))!.draw(in: background, angle: 75)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 242, y: 344, width: 540, height: 365), xRadius: 38, yRadius: 38)
        screen.lineWidth = 30
        screen.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 340)); stand.line(to: NSPoint(x: 512, y: 270))
        stand.move(to: NSPoint(x: 415, y: 263)); stand.line(to: NSPoint(x: 609, y: 263))
        stand.lineWidth = 30; stand.lineCapStyle = .round; stand.stroke()
        let prompt = NSBezierPath()
        prompt.move(to: NSPoint(x: 360, y: 578)); prompt.line(to: NSPoint(x: 415, y: 526)); prompt.line(to: NSPoint(x: 360, y: 474))
        prompt.move(to: NSPoint(x: 474, y: 474)); prompt.line(to: NSPoint(x: 624, y: 474))
        prompt.lineWidth = 27; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round; prompt.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
