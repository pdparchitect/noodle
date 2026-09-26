import CoreGraphics
import Foundation
import Surface
import XCTest

final class SurfaceTests: XCTestCase {
    private func image(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A frame keeps the surface's size in points, however small its picture is sent.
    func testFramesAreShrunkButKeepTheSurfaceSize() throws {
        let frame = try XCTUnwrap(SurfaceFrame(image: image(width: 2560, height: 1600, gray: 0.5), size: CGSize(width: 1280, height: 800),
                                               maxPixelSize: 1280))
        XCTAssertEqual(frame.width, 1280)
        XCTAssertEqual(frame.height, 800)
        let decoded = try XCTUnwrap(frame.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1280)
    }

    func testInputRoundTripsThroughJSON() throws {
        let inputs: [SurfaceInput] = [.pointer(.down, x: 10, y: 20, clickCount: 2), .scroll(x: 5, y: 6, dx: 0, dy: -40),
                                      .key(.enter), .text("héllo")]
        for input in inputs {
            XCTAssertEqual(try JSONDecoder().decode(SurfaceInput.self, from: JSONEncoder().encode(input)), input)
        }
    }

    /// Only changed frames travel; a still page costs nothing after its first frame. The pump
    /// ends when the surface is gone.
    func testThePumpSendsOnlyFramesThatChanged() async throws {
        let captured = [0.2, 0.2, 0.7, 0.7, 0.7].map { gray in
            SurfaceFrame(image: image(width: 64, height: 40, gray: gray), size: CGSize(width: 64, height: 40), maxPixelSize: 64)
        }
        let box = Captures(captured)
        var sent: [SurfaceFrame] = []
        for try await frame in SurfacePump.frames(every: .milliseconds(1), capture: { box.next() }) {
            sent.append(frame)
        }
        XCTAssertEqual(sent.count, 2)
    }

    /// A point on the viewer lands on the same spot of the surface, letterboxing included.
    func testViewerPointsMapToSurfacePoints() {
        let surface = CGSize(width: 1280, height: 800)
        let view = CGSize(width: 640, height: 600)
        XCTAssertEqual(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 300), in: view, surface: surface), CGPoint(x: 640, y: 400))
        XCTAssertNil(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 10), in: view, surface: surface), "a click in the letterbox reaches nothing")
    }
}

private final class Captures: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SurfaceFrame?]
    init(_ frames: [SurfaceFrame?]) { self.frames = frames }
    func next() -> SurfaceFrame? { lock.withLock { frames.isEmpty ? nil : frames.removeFirst() } }
}
