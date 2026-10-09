import CoreGraphics
import Foundation

@main enum ScanoutTest {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        // Two rows, a 16-byte prefix, and row padding. The cropped lower-right
        // pixel is green; nearby pixels and padding must not appear in it.
        var bytes = [UInt8](repeating: 0xcc, count: 48)
        bytes.replaceSubrange(16..<24, with: [0, 0, 255, 255, 255, 0, 0, 255])
        bytes.replaceSubrange(32..<40, with: [255, 255, 255, 255, 0, 255, 0, 255])
        func make(_ offset: Int = 16, _ stride: Int = 16, _ crop: CGRect = CGRect(x: 1, y: 1, width: 1, height: 1), _ format: UInt32 = 1) -> CGImage? {
            bytes.withUnsafeBytes { NeptuneScanout.image($0, width: 2, height: 2, stride: stride, offset: offset, format: format, crop: crop) }
        }
        guard let image = make() else { fputs("FAIL: a valid scanout produced no image\n", stderr); exit(1) }
        check(image.width == 1 && image.height == 1, "crop dimensions")
        // Images already delivered to the window must outlive and be independent
        // of the mapping and the next frame's overwrite of the same resource.
        _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        check(pixel == [0, 255, 0, 255], "surface offset, padded stride, BGRA order, crop and snapshot ownership")
        check(make(40) == nil, "reject truncated storage")
        check(make(16, 4) == nil, "reject short stride")
        check(make(-1) == nil, "reject negative offset")
        check(make(16, 16, CGRect(x: 2, y: 0, width: 1, height: 1)) == nil, "reject crop outside surface")
        check(make(16, 16, CGRect(x: 0, y: 0, width: 1, height: 1), 0xffff) == nil, "reject unknown format")
        print("PASS: scanout pixels, crop, stride, snapshot ownership and bounds")
    }
}
