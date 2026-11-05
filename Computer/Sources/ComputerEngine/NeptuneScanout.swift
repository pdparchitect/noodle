import CoreGraphics
import Foundation

/// Copies a packed, linear Neptune surface before the renderer reuses its blob.
enum NeptuneScanout {
    static func image(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int,
                      stride: Int, offset: Int, format: UInt32, crop: CGRect) -> CGImage? {
        guard (1...16384).contains(width), (1...16384).contains(height),
              stride >= width * 4, offset >= 0, offset <= bytes.count,
              stride <= (bytes.count - offset) / height, let base = bytes.baseAddress,
              crop.width > 0, crop.height > 0, crop.minX >= 0, crop.minY >= 0,
              crop.maxX <= CGFloat(width), crop.maxY <= CGFloat(height) else { return nil }
        let info: UInt32
        switch format {
        case 1, 2: info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        case 3, 4: info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        case 67, 134: info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        case 68, 121: info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        default: return nil
        }
        let snapshot = Data(bytes: base + offset, count: stride * height)
        guard let provider = CGDataProvider(data: snapshot as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return image.cropping(to: crop)
    }
}
