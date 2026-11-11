import Foundation
import QRCodeGenerator

/// An invitation link's QR code, as the Noodle apps scan it: drawn in a terminal, or a PNG to send.
public struct InvitationCode {
    /// The light border scanners need around a code, in modules.
    static let margin = 4
    /// Black on bright white, whatever colours the terminal uses, since scanners look for dark on light.
    static let darkOnLight = "\u{1B}[30;107m"
    static let reset = "\u{1B}[0m"

    private let code: QRCode
    var size: Int { code.size }

    public init(link: String) throws {
        // The level Noodle Hub's own codes use.
        code = try QRCode.encode(text: link, ecl: .medium)
    }

    /// Whether the module at `x`, `y`, counted from the outside of the margin, is dark.
    private func isDark(_ x: Int, _ y: Int) -> Bool {
        let x = x - Self.margin, y = y - Self.margin
        return x >= 0 && y >= 0 && x < size && y < size && code.getModule(x: x, y: y)
    }

    /// Two rows of modules a line, in half blocks.
    public var terminal: String {
        let side = size + 2 * Self.margin
        return stride(from: 0, to: side, by: 2).map { y in
            let row = (0..<side).map { x -> Character in
                switch (isDark(x, y), isDark(x, y + 1)) {
                case (false, false): " "
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                }
            }
            return Self.darkOnLight + String(row) + Self.reset
        }.joined(separator: "\n")
    }

    /// A black and white PNG, `scale` pixels a module.
    public func png(scale: Int = 8) -> Data {
        let side = (size + 2 * Self.margin) * scale
        let rowBytes = (side + 7) / 8
        var pixels = [UInt8]()
        pixels.reserveCapacity((rowBytes + 1) * side)
        for y in 0..<side {
            pixels.append(0) // no filter
            var row = [UInt8](repeating: 0xFF, count: rowBytes)
            for x in 0..<side where isDark(x / scale, y / scale) {
                row[x / 8] &= ~(0x80 >> UInt8(x % 8))
            }
            pixels += row
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Width and height, then one bit a pixel, grey, no interlacing.
        png += PNG.chunk("IHDR", PNG.bigEndian(UInt32(side)) + PNG.bigEndian(UInt32(side)) + [1, 0, 0, 0, 0])
        png += PNG.chunk("IDAT", PNG.zlibStored(pixels))
        png += PNG.chunk("IEND", [])
        return png
    }
}

/// Just enough of PNG for a code: chunks with their checksums, and zlib's uncompressed blocks.
private enum PNG {
    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let typed = Array(type.utf8) + body
        return Data(bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed)))
    }

    static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
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

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
