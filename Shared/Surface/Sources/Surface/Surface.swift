import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One picture of a surface: a computer's display, a browser tab or an applet's window.
/// `width` and `height` are the surface's own size in points, which input is given in;
/// the picture itself may be smaller.
public struct SurfaceFrame: Codable, Equatable, Sendable {
    public var jpeg: Data
    public var width: Double
    public var height: Double

    public init(jpeg: Data, width: Double, height: Double) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }

    /// Encodes `image` no larger than `maxPixelSize` on its longer side. Nil when it cannot be encoded.
    public init?(image: CGImage, size: CGSize, maxPixelSize: Int = 1600, quality: Double = 0.6) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let longest = max(image.width, image.height)
        var picture = image
        if longest > maxPixelSize {
            let scale = Double(maxPixelSize) / Double(longest)
            let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            picture = scaled
        }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(jpeg: data as Data, width: size.width, height: size.height)
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    public var cgImage: CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// What a person does to a surface, in the surface's points.
public enum SurfaceInput: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case move, down, drag, up }
    public enum Key: String, Codable, Sendable {
        case enter, tab, escape, backspace, space, left, right, up, down
    }
    case pointer(Phase, x: Double, y: Double, clickCount: Int = 1)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case key(Key)
    case text(String)
}

/// Captures a surface over and over, and passes on only frames that changed.
public enum SurfacePump {
    /// Ends when `capture` returns nil, as when the surface is gone, or throws.
    public static func frames(every interval: Duration,
                              capture: @escaping @Sendable () async throws -> SurfaceFrame?) -> AsyncThrowingStream<SurfaceFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var last: Data?
                do {
                    while !Task.isCancelled {
                        guard let frame = try await capture() else { break }
                        if frame.jpeg != last {
                            last = frame.jpeg
                            continuation.yield(frame)
                        }
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Where a surface sits in a viewer that shows all of it, keeping its shape.
public enum SurfaceGeometry {
    public static func fitted(_ surface: CGSize, in view: CGSize) -> CGRect {
        guard surface.width > 0, surface.height > 0 else { return .zero }
        let scale = min(view.width / surface.width, view.height / surface.height)
        let size = CGSize(width: surface.width * scale, height: surface.height * scale)
        return CGRect(origin: CGPoint(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2), size: size)
    }

    /// The surface point under `point` of a viewer with a top-left origin. Nil outside the surface.
    public static func surfacePoint(_ point: CGPoint, in view: CGSize, surface: CGSize) -> CGPoint? {
        let frame = fitted(surface, in: view)
        guard frame.width > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) * surface.width / frame.width,
                       y: (point.y - frame.minY) * surface.height / frame.height)
    }
}
