import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run this file with an output directory to redraw the scenario's wallpapers.
// Coordinates describe a flat poster; the shared grain is applied after drawing
// so it reads as one printed surface rather than a collection of 3D objects.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
let width = 1200, height = 1800

struct Palette {
    let name: String
    let base: UInt32
    let low: UInt32
    let mid: UInt32
    let high: UInt32
}

let palettes = [
    Palette(name: "geometry-blue", base: 0x12151b, low: 0x171d29, mid: 0x202c40, high: 0x344968),
    Palette(name: "geometry-violet", base: 0x17151c, low: 0x211b2b, mid: 0x30273f, high: 0x4b3d61),
    Palette(name: "geometry-teal", base: 0x11191a, low: 0x172426, mid: 0x203638, high: 0x355153)
]

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

for (variant, palette) in palettes.enumerated() {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color(palette.base))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    func polygon(_ points: [(CGFloat, CGFloat)], _ fill: UInt32) {
        context.beginPath()
        context.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
        context.closePath()
        context.setFillColor(color(fill))
        context.fillPath()
    }

    func square(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ fill: UInt32) {
        context.setFillColor(color(fill))
        context.fill(CGRect(x: x, y: y, width: size, height: size))
    }

    switch variant {
    case 0:
        // An interrupted diagonal balances the square's strict vertical edges.
        square(510, 170, 780, palette.low)
        polygon([(-180, 1540), (1120, 240), (1120, 1540)], palette.mid)
        polygon([(-180, 1540), (430, 930), (1040, 1540)], palette.high)
        polygon([(650, 1190), (1250, 590), (1250, 1190)], palette.low)
        square(870, 1500, 96, palette.mid)
    case 1:
        // Large cropped squares carry one clean triangular interruption.
        square(-150, 500, 930, palette.low)
        square(380, 960, 890, palette.mid)
        polygon([(160, 1430), (1110, 480), (1110, 1430)], palette.high)
        polygon([(570, 1430), (1110, 890), (1110, 1430)], palette.mid)
        square(140, 1570, 80, palette.high)
    default:
        // Two 45-degree cuts keep the third composition in the same family.
        square(590, -120, 740, palette.low)
        polygon([(-80, 1170), (900, 190), (900, 1170)], palette.mid)
        polygon([(260, 1670), (1180, 750), (1180, 1670)], palette.high)
        square(-120, 1170, 640, palette.low)
        square(790, 1590, 90, palette.mid)
    }

    // A fixed seed makes every redraw identical. Monochrome grain preserves the
    // palette and stays fine enough to remain quiet behind conversation text.
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var random: UInt64 = 0x4e6f6f646c65 + UInt64(variant)
    for y in 0..<height {
        for x in 0..<width {
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            let grain = Int(random % 9) - 4
            let index = (y * width + x) * 4
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(clamping: Int(pixels[index + channel]) + grain)
            }
        }
    }

    let url = output.appendingPathComponent(palette.name + ".png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save \(url.path)") }
    print(url.path)
}
