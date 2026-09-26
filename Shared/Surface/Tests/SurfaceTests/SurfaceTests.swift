import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Surface
import VideoToolbox
import XCTest

final class SurfaceTests: XCTestCase {
    private func image(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1 - gray, alpha: 1)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    func testInputRoundTripsThroughJSON() throws {
        let inputs: [SurfaceInput] = [.pointer(.down, x: 10, y: 20, clickCount: 2), .scroll(x: 5, y: 6, dx: 0, dy: -40),
                                      .key(.enter), .text("héllo")]
        for input in inputs {
            XCTAssertEqual(try JSONDecoder().decode(SurfaceInput.self, from: JSONEncoder().encode(input)), input)
        }
    }

    /// Packets travel as bytes, starting with a byte no JSON starts with.
    func testPacketsRoundTripAsBytes() throws {
        let packets = [SurfacePacket(sequence: 1, keyFrame: true, width: 1280, height: 800, parameterSets: [Data([1, 2]), Data([3])], sample: Data([9, 8, 7])),
                       SurfacePacket(sequence: 2, keyFrame: false, width: 1280, height: 800, parameterSets: [], sample: Data(repeating: 5, count: 1000))]
        let data = SurfacePacket.encode(packets)
        XCTAssertEqual(data.first, SurfacePacket.formatByte)
        XCTAssertNotEqual(data.first, UInt8(ascii: "{"))
        XCTAssertEqual(SurfacePacket.decode(data), packets)
        XCTAssertNil(SurfacePacket.decode(data.dropLast()), "a cut-short packet read as whole")
        XCTAssertNil(SurfacePacket.decode(Data("{}".utf8)))
    }

    /// The Mac's encoder makes H.264 a viewer can decode, at the surface's shape.
    func testEncodedFramesDecode() throws {
        let encoder = SurfaceEncoder(maxPixelSize: 640, fps: 30)
        let first = try XCTUnwrap(try encoder.encode(image(width: 1280, height: 800, gray: 0.2), size: CGSize(width: 640, height: 400)))
        XCTAssertTrue(first.keyFrame)
        XCTAssertEqual(first.parameterSets.count, 2)
        let second = try XCTUnwrap(try encoder.encode(image(width: 1280, height: 800, gray: 0.3), size: CGSize(width: 640, height: 400)))
        XCTAssertFalse(second.keyFrame)
        let packet = SurfacePacket(sequence: 1, keyFrame: true, width: 640, height: 400, parameterSets: first.parameterSets, sample: first.sample)
        let format = try XCTUnwrap(SurfaceSamples.format(packet))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 640)
        XCTAssertEqual(dimensions.height, 400)
        let sample = try XCTUnwrap(SurfaceSamples.sample(packet, format: format))
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
        var decoded: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(try XCTUnwrap(session), sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
            decoded = buffer
        }
        XCTAssertEqual(status, noErr)
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        XCTAssertEqual(decoded.map(CVPixelBufferGetWidth), 640)
    }

    /// A new reader starts at a key frame, a caught-up one gets only what is new, and the
    /// surface counts as watched only while someone keeps reading.
    @MainActor func testTheStreamerServesReadersAndKnowsWhenItIsWatched() async throws {
        let picture = image(width: 320, height: 200, gray: 0.5)
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 320, lease: .milliseconds(300)) { (picture, CGSize(width: 320, height: 200)) }
        XCTAssertFalse(streamer.isWatched)
        XCTAssertEqual(try streamer.read(after: 0), [])
        XCTAssertTrue(streamer.isWatched)
        var packets: [SurfacePacket] = []
        for _ in 0..<50 where packets.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
            packets = try streamer.read(after: 0)
        }
        XCTAssertTrue(packets.first?.keyFrame == true, "a new reader did not start at a key frame")
        XCTAssertEqual(packets.first?.size, CGSize(width: 320, height: 200))
        let last = try XCTUnwrap(packets.last).sequence
        try await Task.sleep(for: .milliseconds(60))
        let newer = try streamer.read(after: last)
        XCTAssertFalse(newer.isEmpty)
        XCTAssertTrue(newer.allSatisfy { $0.sequence > last })
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(streamer.isWatched, "the lease outlived its reader")
    }

    /// A point on the viewer lands on the same spot of the surface, letterboxing included.
    func testViewerPointsMapToSurfacePoints() {
        let surface = CGSize(width: 1280, height: 800)
        let view = CGSize(width: 640, height: 600)
        XCTAssertEqual(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 300), in: view, surface: surface), CGPoint(x: 640, y: 400))
        XCTAssertNil(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 10), in: view, surface: surface), "a click in the letterbox reaches nothing")
    }
}
