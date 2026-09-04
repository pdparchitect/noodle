import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon OUTPUT.png\n", stderr)
    exit(2)
}

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: canvas)
NSColor.clear.setFill()
bounds.fill()

let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 32, dy: 32), xRadius: 218, yRadius: 218)
let gradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.08, green: 0.69, blue: 1.0, alpha: 1), 0),
    (NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.96, alpha: 1), 0.58),
    (NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.90, alpha: 1), 1)
)
gradient?.draw(in: tile, angle: -62)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()

let bubble = NSBezierPath(ovalIn: NSRect(x: 180, y: 270, width: 664, height: 512))
NSColor.white.setFill()
bubble.fill()

let tail = NSBezierPath()
tail.move(to: NSPoint(x: 304, y: 360))
tail.curve(to: NSPoint(x: 205, y: 211), controlPoint1: NSPoint(x: 285, y: 294), controlPoint2: NSPoint(x: 245, y: 242))
tail.curve(to: NSPoint(x: 415, y: 307), controlPoint1: NSPoint(x: 284, y: 224), controlPoint2: NSPoint(x: 356, y: 260))
tail.close()
tail.fill()
NSGraphicsContext.restoreGraphicsState()

let faceColor = NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.88, alpha: 1)
faceColor.setFill()
NSBezierPath(roundedRect: NSRect(x: 348, y: 515, width: 92, height: 74), xRadius: 37, yRadius: 37).fill()
NSBezierPath(roundedRect: NSRect(x: 584, y: 515, width: 92, height: 74), xRadius: 37, yRadius: 37).fill()

faceColor.setStroke()
let smile = NSBezierPath()
smile.lineWidth = 22
smile.lineCapStyle = .round
smile.move(to: NSPoint(x: 414, y: 432))
smile.curve(to: NSPoint(x: 610, y: 432), controlPoint1: NSPoint(x: 466, y: 378), controlPoint2: NSPoint(x: 558, y: 378))
smile.stroke()

NSColor.white.setStroke()
let spark = NSBezierPath()
spark.lineWidth = 18
spark.lineCapStyle = .round
spark.move(to: NSPoint(x: 775, y: 748))
spark.line(to: NSPoint(x: 775, y: 858))
spark.move(to: NSPoint(x: 720, y: 803))
spark.line(to: NSPoint(x: 830, y: 803))
spark.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
