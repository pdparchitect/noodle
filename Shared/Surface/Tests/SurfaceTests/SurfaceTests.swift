import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
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
        for control in inputs.map(SurfaceControl.input) + [.view(width: 1200, height: 800), .keyFrame] {
            XCTAssertEqual(SurfaceControl(control.encoded), control)
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

    /// Two ends of a live view's connection, as a companion and the Hub hold them.
    private func pair() throws -> (SurfaceSocket, SurfaceSocket) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let ends = (SurfaceSocket(fd: fds[0]), SurfaceSocket(fd: fds[1]))
        addTeardownBlock { ends.0.close(); ends.1.close() }
        return ends
    }

    private func packets(from socket: SurfaceSocket, until done: @escaping ([SurfacePacket]) -> Bool) async throws -> [SurfacePacket] {
        let task = Task {
            var received: [SurfacePacket] = []
            for await frame in socket.frames {
                received += SurfacePacket.decode(frame) ?? []
                if done(received) { break }
            }
            return received
        }
        let timeout = Task { try await Task.sleep(for: .seconds(10)); task.cancel() }
        defer { timeout.cancel() }
        return await task.value
    }

    /// Frames cross in order both ways, and closing one end ends the other.
    func testASocketCarriesFramesBothWays() async throws {
        let (companion, hub) = try pair()
        companion.send(Data([1, 2, 3]))
        companion.send(Data(repeating: 7, count: 200_000))
        hub.send(Data("{}".utf8))
        var down: [Data] = []
        for await frame in hub.frames { down.append(frame); if down.count == 2 { break } }
        XCTAssertEqual(down, [Data([1, 2, 3]), Data(repeating: 7, count: 200_000)])
        for await frame in companion.frames { XCTAssertEqual(frame, Data("{}".utf8)); break }
        companion.close()
        var more = 0
        for await _ in hub.frames { more += 1 }
        XCTAssertEqual(more, 0)
    }

    /// Video starts at a key frame as soon as someone watches, fits the viewer's window in
    /// steps, and what the viewer does reaches the surface in the order they did it.
    @MainActor func testTheStreamerPushesVideoAndTakesInput() async throws {
        let picture = image(width: 1600, height: 1000, gray: 0.5)
        var applied: [SurfaceInput] = []
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 1600, capture: { (picture, CGSize(width: 800, height: 500)) },
                                       apply: { applied.append($0) })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        XCTAssertFalse(streamer.isWatched)
        streamer.attach(companion)
        XCTAssertTrue(streamer.isWatched)

        let first = try await packets(from: hub) { $0.count >= 3 }
        XCTAssertEqual(first.first?.keyFrame, true, "video did not start at a key frame")
        XCTAssertEqual(first.first?.size, CGSize(width: 800, height: 500))
        XCTAssertEqual(first.first.flatMap(SurfaceSamples.format).map(CMVideoFormatDescriptionGetDimensions)?.width, 1600)

        // 400 × 400 rounds up to a 512 box; the surface keeps its shape inside it.
        hub.send(SurfaceControl.view(width: 400, height: 400).encoded)
        let fitted = try await packets(from: hub) { received in
            received.contains { $0.keyFrame && SurfaceSamples.format($0).map(CMVideoFormatDescriptionGetDimensions)?.width == 512 }
        }
        let key = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(fitted.last { $0.keyFrame }.flatMap(SurfaceSamples.format)))
        XCTAssertEqual(key.width, 512)
        XCTAssertEqual(key.height, 320)

        let click: [SurfaceInput] = [.pointer(.down, x: 5, y: 5), .pointer(.up, x: 5, y: 5), .text("go")]
        click.forEach { hub.send(SurfaceControl.input($0).encoded) }
        for _ in 0..<100 where applied.count < click.count { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(applied, click)

        hub.close()
        for _ in 0..<100 where streamer.isWatched { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(streamer.isWatched, "the view stayed watched after its viewer left")
    }

    /// A viewer that falls behind misses frames rather than getting old ones late, and always
    /// picks up again at a key frame, since the frames between depend on the ones before.
    @MainActor func testASlowViewerSkipsToTheNextKeyFrame() async throws {
        let pictures = (0..<8).map { noise(width: 800, height: 500, seed: CGFloat($0) / 8) }
        var next = 0
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 800, capture: {
            next += 1
            return (pictures[next % pictures.count], CGSize(width: 800, height: 500))
        }, apply: { _ in })
        defer { streamer.stop() }
        // A small buffer and a reader that stops reading for a while, as a slow network would be.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        var buffer: Int32 = 4096
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        }
        let companion = SurfaceSocket(fd: fds[0]), reader = fds[1]
        defer { companion.close(); close(reader) }
        streamer.attach(companion)
        // Until the viewer is behind, then long enough for frames to pass it by.
        for _ in 0..<500 where companion.pending < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(companion.pending, 3, "the viewer never fell behind")
        try await Task.sleep(for: .milliseconds(500))
        let received = await Task.detached { () -> [SurfacePacket] in
            func read(_ count: Int) -> Data? {
                var data = Data(count: count), offset = 0
                while offset < count {
                    let got = data.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress!.advanced(by: offset), count - offset) }
                    guard got > 0 else { return nil }
                    offset += got
                }
                return data
            }
            var packets: [SurfacePacket] = []
            while packets.count < 40, let header = read(4), let frame = read(header.reduce(0) { ($0 << 8) | Int($1) }) {
                packets += SurfacePacket.decode(frame) ?? []
            }
            return packets
        }.value
        XCTAssertEqual(received.first?.keyFrame, true)
        var gaps = 0
        for (before, after) in zip(received, received.dropFirst()) where after.sequence != before.sequence + 1 {
            gaps += 1
            XCTAssertTrue(after.keyFrame, "after missing frames, video resumed at \(after.sequence), which is not a key frame")
        }
        XCTAssertGreaterThan(gaps, 0, "a viewer that fell behind got every frame late")
    }

    private func noise(width: Int, height: Int, seed: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: .random(in: 0...1, using: &generator), green: seed, blue: .random(in: 0...1, using: &generator), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return context.makeImage()!
    }

    /// A point on the viewer lands on the same spot of the surface, letterboxing included.
    func testViewerPointsMapToSurfacePoints() {
        let surface = CGSize(width: 1280, height: 800)
        let view = CGSize(width: 640, height: 600)
        XCTAssertEqual(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 300), in: view, surface: surface), CGPoint(x: 640, y: 400))
        XCTAssertNil(SurfaceGeometry.surfacePoint(CGPoint(x: 320, y: 10), in: view, surface: surface), "a click in the letterbox reaches nothing")
    }
}
