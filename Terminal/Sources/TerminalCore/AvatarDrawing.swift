import Foundation

/// Bots' pictures drawn as pixels, where there is no Mac drawing to make them: each bot's colours in a
/// circle, a group's first bots together on a disc, paler while they are not running. The colours and
/// layout are the Mac's; the symbol on top is not, since only Apple systems have the symbols.
public enum AvatarDrawing {
    public struct Picture: Equatable, Sendable {
        public let side: Int
        /// Red, green, blue and alpha for each pixel, row by row from the top.
        public var bytes: [UInt8]

        public func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let index = (y * side + x) * 4
            return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
        }
    }

    private struct Colour { let red, green, blue, alpha: Double }

    /// The Mac's avatar gradients, as its system colours look: blue to cyan, purple to pink, orange to yellow,
    /// mint to teal, indigo to blue, pink to orange.
    private static let gradients: [(Colour, Colour)] = [
        (Colour(red: 0, green: 122, blue: 255, alpha: 1), Colour(red: 50, green: 173, blue: 230, alpha: 1)),
        (Colour(red: 175, green: 82, blue: 222, alpha: 1), Colour(red: 255, green: 45, blue: 85, alpha: 1)),
        (Colour(red: 255, green: 149, blue: 0, alpha: 1), Colour(red: 255, green: 204, blue: 0, alpha: 1)),
        (Colour(red: 0, green: 199, blue: 190, alpha: 1), Colour(red: 48, green: 176, blue: 199, alpha: 1)),
        (Colour(red: 88, green: 86, blue: 214, alpha: 1), Colour(red: 0, green: 122, blue: 255, alpha: 1)),
        (Colour(red: 255, green: 45, blue: 85, alpha: 1), Colour(red: 255, green: 149, blue: 0, alpha: 1)),
    ]
    /// The disc a group's bots sit on, as the Mac's tertiary label colour.
    private static let groupDisc = Colour(red: 60, green: 60, blue: 67, alpha: 0.3)

    /// Bots' colours, indexed as the Mac indexes them, drawn `scale` of the way across a square of `side` pixels.
    public static func picture(colours: [Int], dimmed: Bool, scale: Double, side: Int = 48) -> Picture {
        var picture = Picture(side: side, bytes: [UInt8](repeating: 0, count: side * side * 4))
        let size = Double(side) * scale
        let centre = Double(side) / 2
        let shown = Array(colours.prefix(3))
        switch shown.count {
        case 0, 1:
            disc(&picture, centreX: centre, centreY: centre, diameter: size, gradient: shown.first ?? 0)
        default:
            disc(&picture, centreX: centre, centreY: centre, diameter: size, flat: groupDisc)
            let each = size * (shown.count == 2 ? 0.6 : 0.62)
            for (index, colour) in shown.enumerated() {
                let offset = groupOffset(index, of: shown.count, size: size)
                disc(&picture, centreX: centre + offset.x, centreY: centre + offset.y, diameter: each, gradient: colour)
            }
        }
        if dimmed {
            for index in stride(from: 3, to: picture.bytes.count, by: 4) {
                picture.bytes[index] = UInt8((Double(picture.bytes[index]) * 0.45).rounded())
            }
        }
        return picture
    }

    /// As the Mac lays out a group's bots, measured downwards: two across the middle, three in a triangle.
    private static func groupOffset(_ index: Int, of count: Int, size: Double) -> (x: Double, y: Double) {
        switch (count, index) {
        case (2, 0): (-size * 0.14, -size * 0.14)
        case (2, _): (size * 0.14, size * 0.14)
        case (_, 0): (-size * 0.18, -size * 0.14)
        case (_, 1): (size * 0.18, -size * 0.14)
        default: (0, size * 0.19)
        }
    }

    private static func disc(_ picture: inout Picture, centreX: Double, centreY: Double, diameter: Double,
                             gradient index: Int? = nil, flat: Colour? = nil) {
        let radius = diameter / 2
        let colours = index.map { gradients[Int($0.magnitude % UInt(gradients.count))] }
        for y in 0..<picture.side {
            for x in 0..<picture.side {
                let dx = Double(x) + 0.5 - centreX, dy = Double(y) + 0.5 - centreY
                // Edges are softened by how much of the pixel the circle covers.
                let coverage = min(1, max(0, radius - (dx * dx + dy * dy).squareRoot() + 0.5))
                guard coverage > 0 else { continue }
                var colour = flat ?? Colour(red: 0, green: 0, blue: 0, alpha: 0)
                if let colours {
                    // From the top left to the bottom right, as the Mac's gradient at -45°.
                    let t = min(1, max(0, (dx + dy) / (2 * diameter) + 0.5))
                    colour = Colour(red: colours.0.red + (colours.1.red - colours.0.red) * t,
                                    green: colours.0.green + (colours.1.green - colours.0.green) * t,
                                    blue: colours.0.blue + (colours.1.blue - colours.0.blue) * t, alpha: 1)
                }
                blend(&picture, x: x, y: y, colour, alpha: colour.alpha * coverage)
            }
        }
    }

    /// Lays `colour` over what the pixel holds.
    private static func blend(_ picture: inout Picture, x: Int, y: Int, _ colour: Colour, alpha: Double) {
        let index = (y * picture.side + x) * 4
        let below = Double(picture.bytes[index + 3]) / 255
        let out = alpha + below * (1 - alpha)
        guard out > 0 else { return }
        for (channel, value) in [colour.red, colour.green, colour.blue].enumerated() {
            let under = Double(picture.bytes[index + channel])
            picture.bytes[index + channel] = UInt8(((value * alpha + under * below * (1 - alpha)) / out).rounded())
        }
        picture.bytes[index + 3] = UInt8((out * 255).rounded())
    }

    /// Whether `data` is a picture a terminal can show as it is: a PNG or a JPEG.
    public static func isShowable(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    /// The picture as a PNG, uncompressed: a few kilobytes for an avatar.
    public static func png(_ picture: Picture) -> [UInt8] {
        let row = picture.side * 4
        var pixels = [UInt8]()
        pixels.reserveCapacity((row + 1) * picture.side)
        for y in 0..<picture.side {
            pixels.append(0)
            pixels += picture.bytes[y * row..<(y + 1) * row]
        }
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // Width and height, then eight bits a channel of colour with alpha.
        png += chunk("IHDR", bigEndian(UInt32(picture.side)) + bigEndian(UInt32(picture.side)) + [8, 6, 0, 0, 0])
        png += chunk("IDAT", stored(pixels))
        png += chunk("IEND", [])
        return png
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
    }

    /// zlib's uncompressed blocks, with its checksum.
    private static func stored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let last: UInt8 = offset + count == bytes.count ? 1 : 0
            out += [last, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8(~count >> 8 & 0xFF)]
            out += bytes[offset..<offset + count]
            offset += count
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return out + bigEndian(b << 16 | a)
    }

    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
