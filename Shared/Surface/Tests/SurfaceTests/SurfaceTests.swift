import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
@testable import Surface
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
        for control in inputs.map(SurfaceControl.input) + [.view(width: 1200, height: 800), .keyFrame, .rate(bitsPerSecond: 1_000_000)] {
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

    /// A red square top left on white, in the layout WebKit snapshots come in or in another.
    private func marked(width: Int, height: Int, webKitLayout: Bool) -> CGImage {
        let info = webKitLayout ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                                : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // Core Graphics counts rows from the bottom.
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    /// The colour at a point of a decoded frame, as the display would show it.
    private func decodedColour(_ encoded: SurfaceEncoder.Frame,
                               at point: (x: Double, y: Double)) throws -> (red: Int, green: Int, blue: Int) {
        let packet = SurfacePacket(sequence: 1, keyFrame: true, width: 1, height: 1, parameterSets: encoded.parameterSets, sample: encoded.sample)
        let format = try XCTUnwrap(SurfaceSamples.format(packet))
        let sample = try XCTUnwrap(SurfaceSamples.sample(packet, format: format))
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session), noErr)
        var decoded: CVImageBuffer?
        VTDecompressionSessionDecodeFrame(try XCTUnwrap(session), sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
            decoded = buffer
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        let buffer = try XCTUnwrap(decoded)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let x = Int(point.x * Double(CVPixelBufferGetWidth(buffer))), y = Int(point.y * Double(CVPixelBufferGetHeight(buffer)))
        let pixel = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
    }

    /// Scaled down, the picture keeps its colours and which way up it is, whichever layout it came in.
    func testEncodedFramesShowThePicture() throws {
        for webKitLayout in [true, false] {
            let encoder = SurfaceEncoder(maxPixelSize: 640, fps: 30)
            let encoded = try XCTUnwrap(try encoder.encode(marked(width: 1280, height: 800, webKitLayout: webKitLayout),
                                                           size: CGSize(width: 640, height: 400)))
            let red = try decodedColour(encoded, at: (0.25, 0.25)), white = try decodedColour(encoded, at: (0.75, 0.75))
            XCTAssert(red.red > 200 && red.green < 60 && red.blue < 60, "top left \(red), WebKit layout \(webKitLayout)")
            XCTAssert(white.red > 220 && white.green > 220 && white.blue > 220, "bottom right \(white), WebKit layout \(webKitLayout)")
        }
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

    /// Viewers hear why the surface shows nothing new as they arrive and whenever that changes, and
    /// nothing else reads the status as one.
    @MainActor func testViewersHearWhyTheSurfaceShowsNothingNew() async throws {
        let picture = image(width: 800, height: 500, gray: 0.5)
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 800, capture: { (picture, CGSize(width: 800, height: 500)) }, apply: { _ in })
        defer { streamer.stop() }
        streamer.notice = .starting
        let (companion, hub) = try pair()
        streamer.attach(companion)
        var heard: [SurfaceNotice?] = []
        let listening = Task {
            for await frame in hub.frames {
                if let status = SurfaceStatus(frame) { heard.append(status.notice) }
                if heard.count == 3 { break }
            }
        }
        for _ in 0..<100 where heard.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        streamer.notice = .notResponding
        streamer.notice = nil
        let timeout = Task { try await Task.sleep(for: .seconds(10)); listening.cancel() }
        await listening.value
        timeout.cancel()
        XCTAssertEqual(heard, [.starting, .notResponding, nil])

        XCTAssertEqual(SurfaceStatus(SurfaceStatus(notice: nil).encoded), SurfaceStatus(notice: nil))
        XCTAssertNil(SurfaceStatus(Data("{}".utf8)))
        XCTAssertNil(SurfaceStatus(Data(#"{"surfaceOpened":{"sessionID":"00000000-0000-0000-0000-000000000000"}}"#.utf8)))
        XCTAssertNil(SurfaceStatus(SurfaceControl.keyFrame.encoded))
    }

    /// A surface that stops changing settles in a few frames and then sends nothing, until it
    /// changes again or a viewer asks for a key frame.
    @MainActor func testAStillSurfaceStopsSendingUntilItChanges() async throws {
        let still = image(width: 800, height: 500, gray: 0.5), changed = image(width: 800, height: 500, gray: 0.8)
        var picture = still
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 800, capture: { (picture, CGSize(width: 800, height: 500)) }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        streamer.attach(companion)
        // One reader for the whole test: a quiet stream must stay open to show what comes later.
        var received: [SurfacePacket] = []
        let reader = Task { @MainActor in for await frame in hub.frames { received += SurfacePacket.decode(frame) ?? [] } }
        defer { reader.cancel() }
        func wait(_ label: String, until done: () -> Bool) async throws {
            for _ in 0..<250 where !done() { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(done(), label)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(received.first?.keyFrame, true)
        XCTAssertLessThan(received.count, 15, "a still surface sent \(received.count) frames in a second")

        let quiet = received.count
        picture = changed
        try await wait("a change was not sent") { received.count > quiet }
        try await Task.sleep(for: .milliseconds(500))
        let settled = received.count
        hub.send(SurfaceControl.keyFrame.encoded)
        try await wait("a key frame asked for on a still surface never came") { received.dropFirst(settled).contains(where: \.keyFrame) }
    }

    /// A settled surface is looked at only now and then, and at full pace again as soon as the
    /// viewer does something, since that is when it is about to change.
    @MainActor func testAStillSurfaceIsCapturedLessUntilTheViewerActs() async throws {
        let picture = image(width: 800, height: 500, gray: 0.5)
        var captures = 0
        let streamer = SurfaceStreamer(fps: 60, maxPixelSize: 800, capture: {
            captures += 1
            return (picture, CGSize(width: 800, height: 500))
        }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        streamer.attach(companion)
        let reader = Task { for await _ in hub.frames {} }
        defer { reader.cancel() }
        func captured(over interval: Duration) async throws -> Int {
            let before = captures
            try await Task.sleep(for: interval)
            return captures - before
        }
        // The attach itself counts as the viewer acting.
        try await Task.sleep(for: .seconds(1.5))
        let still = try await captured(over: .seconds(1))
        XCTAssertLessThan(still, 20, "a still surface was captured \(still) times a second")

        hub.send(SurfaceControl.input(.pointer(.move, x: 1, y: 1)).encoded)
        // Half a second, so compare per second: a slow runner's full pace is only a few frames more.
        let acting = try await captured(over: .milliseconds(500)) * 2
        XCTAssertGreaterThan(acting, still, "input did not bring back the full pace")
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

    /// A viewer on a slow link asks for less, and the video it gets shrinks to fit.
    @MainActor func testTheStreamerKeepsToTheRateAViewerAsksFor() async throws {
        // Rate control is the hardware encoder's; the software one in a virtual machine keeps its own pace.
        try skipWithoutHardwareEncoder()
        let pictures = (0..<8).map { noise(width: 800, height: 500, seed: CGFloat($0) / 8) }
        var next = 0
        let streamer = SurfaceStreamer(fps: 30, maxPixelSize: 800, capture: {
            next += 1
            return (pictures[next % pictures.count], CGSize(width: 800, height: 500))
        }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        streamer.attach(companion)
        // The encoder keeps to a rate by dropping frames as well as by shrinking them, so count bytes a second.
        func bytesPerSecond() async throws -> Double {
            let start = ContinuousClock.now
            let frames = try await packets(from: hub) { _ in ContinuousClock.now - start > .seconds(2) }.filter { !$0.keyFrame }
            return Double(frames.reduce(0) { $0 + $1.sample.count }) / ((ContinuousClock.now - start) / .seconds(1))
        }
        let full = try await bytesPerSecond()
        hub.send(SurfaceControl.rate(bitsPerSecond: 100_000).encoded)
        let slowed = try await bytesPerSecond()
        XCTAssertLessThan(slowed, full / 2, "video stayed at \(Int(slowed)) bytes a second, from \(Int(full)), after the viewer asked for less")
    }

    /// A surface captured less often than the encoder's frame rate still gets the rate it was
    /// given: rate control goes by when each picture was taken, not by how many pictures came.
    func testFramesCapturedLessOftenStillGetTheWholeRate() throws {
        try skipWithoutHardwareEncoder()
        let pictures = (0..<8).map { noise(width: 800, height: 500, seed: CGFloat($0) / 8) }
        let encoder = SurfaceEncoder(maxPixelSize: 800, fps: 60)
        encoder.bitRate = 1_000_000
        var bytes = 0
        // Four seconds at 20 frames a second, after two for rate control to find its level.
        for index in 0..<120 {
            let encoded = try encoder.encode(pictures[index % pictures.count], size: CGSize(width: 800, height: 500), at: Double(index) / 20)
            if index >= 40 { bytes += encoded?.sample.count ?? 0 }
        }
        let bitsPerSecond = Double(bytes) * 8 / 4
        XCTAssertGreaterThan(bitsPerSecond, 600_000, "video came at \(Int(bitsPerSecond)) bits a second of the 1,000,000 it may use")
    }

    /// Video that keeps moving gets key frames only when asked for. The link loses nothing, and a
    /// key frame costs as much as a hundred others, so one on a timer would only stall a slow link.
    func testKeyFramesComeOnlyWhenAskedFor() throws {
        // Plain enough that rate control drops none of them.
        let pictures = (0..<8).map { image(width: 320, height: 200, gray: CGFloat($0) / 8) }
        let encoder = SurfaceEncoder(maxPixelSize: 320, fps: 30)
        var keyFrames: [Int] = []
        for index in 0..<180 {
            let asked = index == 150
            if try encoder.encode(pictures[index % pictures.count], size: CGSize(width: 320, height: 200), keyFrame: asked,
                                  at: Double(index) / 30)?.keyFrame == true { keyFrames.append(index) }
        }
        XCTAssertEqual(keyFrames, [0, 150], "six seconds of video had key frames at \(keyFrames)")
    }

    /// A page of text-like lines, scrolled up by `offset` pixels.
    private func page(width: Int, height: Int, offset: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.1, alpha: 1)
        var state: UInt64 = 7
        for line in 0..<(height / 12) {
            var x = 20
            while x < width - 20 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let word = Int(state >> 58) + 6
                context.fill(CGRect(x: x, y: height - (line * 24 - offset) - 16, width: word, height: 12))
                x += word + 8
            }
        }
        return context.makeImage()!
    }

    /// The last picture a decoder shows after being given `frames`, in order.
    private func decoded(_ frames: [SurfaceEncoder.Frame]) throws -> CVPixelBuffer {
        let first = try XCTUnwrap(frames.first)
        let format = try XCTUnwrap(SurfaceSamples.format(SurfacePacket(sequence: 1, keyFrame: true, width: 1, height: 1,
                                                                        parameterSets: first.parameterSets, sample: first.sample)))
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session), noErr)
        var last: CVImageBuffer?
        for frame in frames {
            let packet = SurfacePacket(sequence: 1, keyFrame: frame.keyFrame, width: 1, height: 1, parameterSets: [], sample: frame.sample)
            let sample = try XCTUnwrap(SurfaceSamples.sample(packet, format: format))
            VTDecompressionSessionDecodeFrame(try XCTUnwrap(session), sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
                if status == noErr { last = buffer }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session!)
        }
        return try XCTUnwrap(last)
    }

    /// How far a decoded picture is from the one encoded: the mean difference of its green, 0 to 255.
    private func difference(_ decoded: CVPixelBuffer, _ image: CGImage) -> Double {
        let width = CVPixelBufferGetWidth(decoded), height = CVPixelBufferGetHeight(decoded)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let pixels = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(decoded)
        var total = 0
        for y in 0..<height { for x in 0..<width { total += abs(Int(pixels[y * row + x * 4 + 1]) - Int(source[y * width * 4 + x * 4 + 1])) } }
        return Double(total) / Double(width * height)
    }

    /// A viewer that missed frames goes on from a recovery frame built on one it has shown: a
    /// fraction of the size of a key frame, and the picture as it is.
    func testAViewerThatMissedFramesRecoversWithoutAKeyFrame() throws {
        // Long-term references are the hardware encoder's.
        try skipWithoutHardwareEncoder()
        let encoder = SurfaceEncoder(maxPixelSize: 800, fps: 30)
        var frames: [SurfaceEncoder.Frame] = []
        for index in 0..<60 {
            let frame = try XCTUnwrap(try encoder.encode(page(width: 800, height: 500, offset: index * 3), size: CGSize(width: 800, height: 500),
                                                         at: Double(index) / 30))
            frames.append(frame)
            // The viewer shows the first 31 frames, then falls behind and misses the rest.
            if index <= 30, let token = frame.token { encoder.acknowledge([token]) }
        }
        let now = page(width: 800, height: 500, offset: 180)
        let recovery = try XCTUnwrap(try encoder.encode(now, size: CGSize(width: 800, height: 500), at: 2, recover: true))
        XCTAssertTrue(recovery.recovery, "the frame after missed ones was not a recovery frame")
        XCTAssertFalse(recovery.keyFrame)
        let shown = try decoded(Array(frames[0...30]) + [recovery])
        XCTAssertLessThan(difference(shown, now), 2, "a viewer that missed frames did not see the picture as it is")

        let keyFrame = try XCTUnwrap(try encoder.encode(now, size: CGSize(width: 800, height: 500), keyFrame: true, at: 2.1))
        // Macs' encoders differ in how small they make each: 6.6 times here, 4.8 on a CI runner.
        XCTAssertLessThan(recovery.sample.count * 3, keyFrame.sample.count,
                          "recovering took \(recovery.sample.count) bytes, a key frame \(keyFrame.sample.count)")
    }

    /// A viewer that cannot show what comes next asks once for a key frame, and waits for it
    /// rather than showing frames that build on a picture it does not have.
    @MainActor func testAViewerWithNothingToBuildOnAsksForAKeyFrame() throws {
        let encoder = SurfaceEncoder(maxPixelSize: 320, fps: 30)
        let encoded = try (0..<3).map { index in
            try XCTUnwrap(try encoder.encode(noise(width: 320, height: 200, seed: CGFloat(index) / 3), size: CGSize(width: 320, height: 200),
                                             keyFrame: index == 2, at: Double(index) / 30))
        }
        let packets = encoded.enumerated().map { index, frame in
            SurfacePacket(sequence: UInt64(index + 1), keyFrame: frame.keyFrame, width: 320, height: 200,
                          parameterSets: frame.parameterSets, sample: frame.sample)
        }
        let display = SurfaceDisplay()
        var asked = 0
        display.needsKeyFrame = { asked += 1 }
        // Joined after the first key frame: the next frame needs a picture the viewer never had.
        display.show(packets[1])
        display.show(packets[1])
        XCTAssertEqual(asked, 1, "a viewer with nothing to build on asked \(asked) times for a key frame")
        display.show(packets[2])
        display.show(packets[1])
        XCTAssertEqual(asked, 1, "a viewer showing video asked again for a key frame")
    }

    /// Whoever the viewer's controls go to learns its size and that it says what it has shown,
    /// also when that is set after the view is laid out, as when its channel opens later.
    @MainActor func testANewChannelLearnsTheViewersSize() throws {
        let view = SurfaceNSView(feed: SurfaceFeed())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.layout()
        var controls: [SurfaceControl] = []
        view.control = { controls.append($0) }
        let pixels = view.convertToBacking(view.bounds).size
        XCTAssertEqual(controls, [.view(width: pixels.width, height: pixels.height), .shown(sequence: 0)])
    }

    /// A viewer says which frame it has shown, so the Hub can tell how late video reaches it.
    @MainActor func testAViewerSaysWhatItHasShown() throws {
        let encoded = try XCTUnwrap(try SurfaceEncoder(maxPixelSize: 320, fps: 30).encode(image(width: 320, height: 200, gray: 0.5),
                                                                                        size: CGSize(width: 320, height: 200)))
        let feed = SurfaceFeed()
        let view = SurfaceNSView(feed: feed)
        var controls: [SurfaceControl] = []
        view.control = { controls.append($0) }
        feed.receive([SurfacePacket(sequence: 7, keyFrame: true, width: 320, height: 200, parameterSets: encoded.parameterSets, sample: encoded.sample)])
        XCTAssertEqual(controls, [.shown(sequence: 0), .shown(sequence: 7)])
    }

    /// A frame that takes a few milliseconds longer than the shortest round trip is not late:
    /// every link wavers that much, and taking it for a queue would slow video for nothing.
    func testAFrameThatWaversIsNotLate() {
        let delivery = SurfaceDelivery()
        delivery.sent(1, bytes: 500, at: 0)
        delivery.shown(1, at: 0.003)
        delivery.sent(2, bytes: 9000, at: 1)
        XCTAssertEqual(delivery.late(at: 1.012), 0, "a frame 9 ms slower than the fastest counted as late")
        XCTAssertEqual(delivery.late(at: 1.1), 9000)
    }

    /// Round trips that swing because a line fills and empties do not widen the room given for a
    /// wavering link without end: that would hide the very line that makes them swing.
    func testALineThatSwingsStillShowsAsLate() {
        let delivery = SurfaceDelivery()
        delivery.sent(1, bytes: 500, at: 0)
        delivery.shown(1, at: 0.02)
        // Round trips that swing by half a second, as a line filling and emptying makes them.
        var time = 0.0
        for sequence in UInt64(2)...40 {
            time += 0.1
            delivery.sent(sequence, bytes: 1000, at: time)
            delivery.shown(sequence, at: time + (sequence % 2 == 0 ? 0.02 : 0.5))
        }
        delivery.sent(41, bytes: 5000, at: 10)
        XCTAssertEqual(delivery.late(at: 10.2), 5000, "a frame 200 ms late was not late after round trips swung")
    }

    /// Video counts as late once it has been on its way longer than the shortest round trip and
    /// the viewer has not shown it. A viewer too old to say what it has shown leaves nothing late.
    func testDeliveryCountsWhatTheViewerHasNotShown() {
        let silent = SurfaceDelivery()
        for sequence in 1...5000 { silent.sent(UInt64(sequence), bytes: 1000, at: Double(sequence) / 30) }
        XCTAssertEqual(silent.late(at: 200), 0, "a viewer that never says what it has shown made video late")

        let delivery = SurfaceDelivery()
        delivery.sent(1, bytes: 500, at: 0)
        delivery.shown(1, at: 0.05)
        delivery.sent(2, bytes: 1000, at: 1)
        delivery.sent(3, bytes: 2000, at: 1.1)
        XCTAssertEqual(delivery.late(at: 1.04), 0, "a frame still within a round trip counted as late")
        XCTAssertEqual(delivery.late(at: 1.2), 3000)
        delivery.shown(2, at: 1.25)
        XCTAssertEqual(delivery.late(at: 1.35), 2000, "a frame shown still counted as late")

        // A path that gets slower for good is learnt again while the line drains, instead of
        // leaving every frame late.
        delivery.shown(3, at: 1.3)
        XCTAssertGreaterThan(delivery.fastestAge(at: 20), SurfaceDelivery.memory)
        delivery.beginProbe()
        delivery.sent(4, bytes: 1000, at: 20)
        delivery.shown(4, at: 20.5)
        delivery.endProbe(at: 20.5)
        delivery.sent(5, bytes: 1000, at: 21)
        XCTAssertEqual(delivery.late(at: 21.3), 0)
    }

    /// Recovery frames say so, and so do frames from a companion that can make them. A key
    /// frame's flags stay exactly what older Hubs and viewers look for.
    func testPacketsCarryRecoveryFlags() throws {
        let packets = [SurfacePacket(sequence: 1, keyFrame: true, width: 8, height: 8, parameterSets: [Data([1]), Data([2])], sample: Data([3])),
                       SurfacePacket(sequence: 2, keyFrame: false, recovery: true, recoverable: true, width: 8, height: 8, parameterSets: [], sample: Data([4])),
                       SurfacePacket(sequence: 3, keyFrame: false, recoverable: true, width: 8, height: 8, parameterSets: [], sample: Data([5]))]
        XCTAssertEqual(packets.map { SurfacePacket.decode(SurfacePacket.encode([$0])) }, packets.map { [$0] })
        // The format byte, the packet count and the sequence come first.
        XCTAssertEqual(SurfacePacket.encode([packets[0]])[13], 1)
        XCTAssertNotEqual(SurfacePacket.encode([packets[1]])[13], 1)
        XCTAssertNotEqual(SurfacePacket.encode([packets[2]])[13], 1)
    }

    /// A viewer that says what it has shown and then falls behind goes on from a recovery frame
    /// instead of a key frame.
    @MainActor func testAViewerThatFallsBehindGoesOnFromARecoveryFrame() async throws {
        try skipWithoutHardwareEncoder()
        var offset = 0
        let streamer = SurfaceStreamer(fps: 30, maxPixelSize: 800, capture: {
            offset += 3
            return (self.page(width: 800, height: 500, offset: offset), CGSize(width: 800, height: 500))
        }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        streamer.attach(companion)
        var received: [SurfacePacket] = []
        for await frame in hub.frames {
            for packet in SurfacePacket.decode(frame) ?? [] {
                received.append(packet)
                if received.count <= 20 { hub.send(SurfaceControl.shown(sequence: packet.sequence).encoded) }
                if received.count == 30 { hub.send(SurfaceControl.recover.encoded) }
            }
            if received.count >= 30, received.dropFirst(30).contains(where: { $0.keyFrame || $0.recovery }) { break }
            if received.count > 120 { break }
        }
        XCTAssertTrue(received.dropFirst().filter { !$0.keyFrame }.allSatisfy(\.recoverable), "frames did not say the companion can recover")
        let resumed = try XCTUnwrap(received.dropFirst(30).first { $0.keyFrame || $0.recovery }, "nothing came to go on from")
        XCTAssertTrue(resumed.recovery, "a viewer that fell behind got a key frame instead of a recovery frame")
        XCTAssertLessThan(resumed.sample.count * 5, try XCTUnwrap(received.first).sample.count)
    }

    /// For a device that says what it has shown, the Hub asks a companion that can recover for a
    /// recovery frame after skipping, and goes on from it.
    func testTheRelayGoesOnFromARecoveryFrame() async throws {
        let (companion, hub) = try pair()
        let link = FakeLink()
        let delivery = SurfaceDelivery()
        let relay = Task {
            await hub.relay(to: { frame in
                link.lock.withLock {
                    link.forwarded += SurfacePacket.decode(frame) ?? []
                    if link.stalled { link.backlog += frame.count }
                }
            }, backlog: { link.lock.withLock { link.stalled ? link.backlog : 0 } }, delivery: delivery)
        }
        func frame(_ sequence: UInt64, key: Bool = false, recovery: Bool = false, bytes: Int) -> Data {
            SurfacePacket.encode([SurfacePacket(sequence: sequence, keyFrame: key, recovery: recovery, recoverable: !key, width: 800, height: 500,
                                                parameterSets: key ? [Data([1]), Data([2])] : [], sample: Data(count: bytes))])
        }
        link.lock.withLock { link.stalled = false }
        companion.send(frame(1, key: true, bytes: 50_000))
        companion.send(frame(2, bytes: 2_000))
        for _ in 0..<250 where link.lock.withLock({ link.forwarded.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        delivery.shown(2)
        // The device stops saying what it shows, as when its link stalls.
        companion.send(frame(3, bytes: 1_000_000))
        // Until the relay takes it as overdue, which on a busy machine is later than the round trip seemed.
        for _ in 0..<250 where delivery.late(at: delivery.now) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        companion.send(frame(4, bytes: 2_000))
        var controls: [SurfaceControl] = []
        let deadline = Task { try await Task.sleep(for: .seconds(5)); companion.close() }
        for await data in companion.frames {
            if let control = SurfaceControl(data) { controls.append(control) }
            if controls.contains(.recover) || controls.contains(.keyFrame) { break }
        }
        deadline.cancel()
        XCTAssertTrue(controls.contains(.recover), "the relay asked for \(controls) instead of a recovery frame")
        delivery.shown(3)
        companion.send(frame(5, bytes: 2_000))
        companion.send(frame(6, recovery: true, bytes: 3_000))
        companion.send(frame(7, bytes: 2_000))
        for _ in 0..<250 where link.lock.withLock({ link.forwarded.count }) < 5 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(link.lock.withLock { link.forwarded.map(\.sequence) }, [1, 2, 3, 6, 7])
        companion.close()
        await relay.value
    }

    /// While the line stays full, the Hub asks once for a frame to go on from, and again only
    /// when there is room for it: every answer goes to every viewer of the surface, and one that
    /// lands in a full line is skipped anyway.
    func testTheRelayAsksOnceWhileTheLineStaysFull() {
        var flow = SurfaceFlow(bitRate: 5_000_000, range: 300_000...20_000_000)
        var time = 0.0
        func admit(_ keyFrame: Bool, backlog: Int) -> SurfaceFlow.Decision {
            time += 1.0 / 30
            return flow.admit(bytes: keyFrame ? 100_000 : 10_000, keyFrame: keyFrame, backlog: backlog, now: time)
        }
        XCTAssertEqual(admit(true, backlog: 0), .send)
        var decisions: [SurfaceFlow.Decision] = []
        // The line stays full while the companion answers every request.
        for _ in 0..<10 { decisions += [admit(false, backlog: 2_000_000), admit(true, backlog: 2_000_000)] }
        XCTAssertEqual(decisions.filter { $0 == .skipUntilKeyFrame }.count, 1, "asked \(decisions.filter { $0 == .skipUntilKeyFrame }.count) times while the line stayed full")
        XCTAssertFalse(decisions.contains(.send))
        // Once there is room, it asks again and goes on from the answer.
        XCTAssertEqual(admit(false, backlog: 0), .skipUntilKeyFrame)
        XCTAssertEqual(admit(true, backlog: 0), .send)
        XCTAssertEqual(admit(false, backlog: 0), .send)
    }

    /// The Hub passes video to a viewer only as fast as the viewer's link takes it: when the link
    /// stalls it asks the companion for less and a key frame, and passes nothing on until the
    /// line has cleared and that key frame comes.
    func testTheRelaySlowsVideoForAViewerThatFallsBehind() async throws {
        let (companion, hub) = try pair()
        let link = FakeLink()
        let relay = Task {
            await hub.relay(to: { frame in
                link.lock.withLock {
                    link.forwarded += SurfacePacket.decode(frame) ?? []
                    if link.stalled { link.backlog += frame.count }
                }
            }, backlog: { link.lock.withLock { link.stalled ? link.backlog : 0 } })
        }
        func frame(_ sequence: UInt64, key: Bool, bytes: Int) -> Data {
            SurfacePacket.encode([SurfacePacket(sequence: sequence, keyFrame: key, width: 800, height: 500,
                                                parameterSets: key ? [Data([1]), Data([2])] : [], sample: Data(count: bytes))])
        }
        companion.send(frame(1, key: true, bytes: 1_000_000))
        companion.send(frame(2, key: false, bytes: 20_000))
        var controls: [SurfaceControl] = []
        for await data in companion.frames {
            if let control = SurfaceControl(data) { controls.append(control) }
            if controls.contains(.keyFrame) { break }
        }
        guard case .rate(let rate)? = controls.first(where: { if case .rate = $0 { true } else { false } }) else {
            return XCTFail("the relay never asked for less video, only \(controls)")
        }
        XCTAssertLessThan(rate, 20_000_000)

        link.lock.withLock { link.stalled = false }
        companion.send(frame(3, key: false, bytes: 20_000))
        companion.send(frame(4, key: true, bytes: 100_000))
        companion.send(frame(5, key: false, bytes: 20_000))
        for _ in 0..<250 where link.lock.withLock({ link.forwarded.count }) < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(link.lock.withLock { link.forwarded.map(\.sequence) }, [1, 4, 5])
        companion.close()
        await relay.value
    }

    /// Frames are captured on a steady beat: time spent capturing one does not push the next back.
    @MainActor func testTheStreamerKeepsItsBeatWhileCapturingTakesTime() async throws {
        // A virtual machine's timers are too coarse to hold a 50 ms beat.
        var virtual: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &virtual, &size, nil, 0)
        try XCTSkipIf(virtual == 1, "this Mac is a virtual machine")
        let picture = image(width: 160, height: 100, gray: 0.5)
        var starts: [ContinuousClock.Instant] = []
        let streamer = SurfaceStreamer(fps: 20, maxPixelSize: 160, capture: {
            starts.append(.now)
            try await Task.sleep(for: .milliseconds(30))
            return (picture, CGSize(width: 160, height: 100))
        }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, _) = try pair()
        streamer.attach(companion)
        for _ in 0..<250 where starts.count < 12 { try await Task.sleep(for: .milliseconds(20)) }
        let intervals = zip(starts, starts.dropFirst()).map { ($1 - $0) / .milliseconds(1) }.sorted()
        XCTAssertLessThan(intervals[intervals.count / 2], 60, "frames came every \(Int(intervals[intervals.count / 2])) ms instead of every 50")
    }

    private func skipWithoutHardwareEncoder() throws {
        var encoders: CFArray?
        VTCopyVideoEncoderList(nil, &encoders)
        try XCTSkipUnless((encoders as? [[String: Any]] ?? []).contains {
            $0[kVTVideoEncoderList_CodecType as String] as? CMVideoCodecType == kCMVideoCodecType_H264
                && $0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool == true
        }, "this Mac has no hardware H.264 encoder")
    }

    /// Encoding happens away from the main thread, which the surface and its app need for themselves.
    @MainActor func testEncodingLeavesTheMainThreadFree() async throws {
        let pictures = (0..<4).map { noise(width: 3200, height: 2000, seed: CGFloat($0) / 4) }
        var next = 0
        let streamer = SurfaceStreamer(fps: 30, maxPixelSize: 1600, capture: {
            next += 1
            return (pictures[next % pictures.count], CGSize(width: 1600, height: 1000))
        }, apply: { _ in })
        defer { streamer.stop() }
        let (companion, hub) = try pair()
        streamer.attach(companion)
        _ = try await packets(from: hub) { $0.count >= 3 }
        let drain = Task.detached { for await _ in hub.frames {} }
        defer { drain.cancel() }
        // Time the main thread spends working, which other processes on a busy machine cannot add to.
        func working() -> Double {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let thread = mach_thread_self()
            defer { mach_port_deallocate(mach_task_self_, thread) }
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
            }
            return Double(info.user_time.seconds + info.system_time.seconds) * 1000
                + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
        }
        XCTAssertEqual(pthread_main_np(), 1)
        let before = working()
        try await Task.sleep(for: .seconds(1))
        let held = working() - before
        XCTAssertLessThan(held, 100, "the main thread worked \(Int(held)) ms of one second")
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

    /// Touching and holding, then moving, presses the pointer, drags it and lets go.
    func testHoldingThenMovingDragsThePointer() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        XCTAssertEqual(touches.hold(.began, at: CGPoint(x: 320, y: 300), surface: surface, view: view), [.pointer(.down, x: 640, y: 400)])
        XCTAssertEqual(touches.hold(.moved, at: CGPoint(x: 330, y: 300), surface: surface, view: view), [.pointer(.drag, x: 660, y: 400)])
        XCTAssertEqual(touches.hold(.ended, at: CGPoint(x: 330, y: 300), surface: surface, view: view), [.pointer(.up, x: 660, y: 400)])
    }

    /// A drag that leaves the picture keeps to its edge and still lets go, so no button stays held.
    func testADragThatLeavesThePictureStillLetsGo() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        _ = touches.hold(.began, at: CGPoint(x: 320, y: 300), surface: surface, view: view)
        XCTAssertEqual(touches.hold(.moved, at: CGPoint(x: 320, y: 10), surface: surface, view: view), [.pointer(.drag, x: 640, y: 0)])
        XCTAssertEqual(touches.hold(.ended, at: CGPoint(x: 700, y: 700), surface: surface, view: view), [.pointer(.up, x: 1280, y: 800)])
    }

    func testHoldingInTheLetterboxDragsNothing() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        XCTAssertEqual(touches.hold(.began, at: CGPoint(x: 320, y: 10), surface: surface, view: view), [])
        XCTAssertEqual(touches.hold(.moved, at: CGPoint(x: 320, y: 300), surface: surface, view: view), [])
        XCTAssertEqual(touches.hold(.ended, at: CGPoint(x: 320, y: 300), surface: surface, view: view), [])
    }

    /// Pinching keeps what is under the fingers there, and taps land on the zoomed picture.
    func testPinchingZoomsAroundTheFingers() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        touches.zoom(by: 2, around: CGPoint(x: 320, y: 300), moved: .zero, surface: surface, view: view)
        XCTAssertEqual(touches.frame(surface, in: view), CGRect(x: -320, y: -100, width: 1280, height: 800))
        XCTAssertEqual(touches.tap(CGPoint(x: 320, y: 300), surface: surface, view: view).first, .pointer(.down, x: 640, y: 400))
        XCTAssertEqual(touches.tap(CGPoint(x: 0, y: 300), surface: surface, view: view).first, .pointer(.down, x: 320, y: 400))
        XCTAssertEqual(touches.scroll(CGPoint(x: 320, y: 300), by: CGPoint(x: 0, y: 10), surface: surface, view: view),
                       [.scroll(x: 640, y: 400, dx: 0, dy: -10)], "a finger scrolls as far as it moves over the zoomed picture")
    }

    /// Two fingers move around the zoomed picture, up to its edges.
    func testTwoFingersMoveAroundTheZoomedPicture() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        touches.zoom(by: 2, around: CGPoint(x: 320, y: 300), moved: .zero, surface: surface, view: view)
        touches.zoom(by: 1, around: CGPoint(x: 320, y: 300), moved: CGPoint(x: 100, y: 0), surface: surface, view: view)
        XCTAssertEqual(touches.frame(surface, in: view).origin, CGPoint(x: -220, y: -100))
        touches.zoom(by: 1, around: CGPoint(x: 320, y: 300), moved: CGPoint(x: 1000, y: -1000), surface: surface, view: view)
        XCTAssertEqual(touches.frame(surface, in: view).origin, CGPoint(x: 0, y: -200))
    }

    /// A zoomed-in viewer asks for as many more pixels as it zooms, so the picture stays sharp.
    func testZoomingInAsksForASharperPicture() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        XCTAssertEqual(touches.pixels(view, screen: 3), CGSize(width: 1920, height: 1800))
        touches.zoom(by: 2, around: CGPoint(x: 320, y: 300), moved: .zero, surface: surface, view: view)
        XCTAssertEqual(touches.pixels(view, screen: 3), CGSize(width: 3840, height: 3600))
        touches.zoom(by: 0.1, around: CGPoint(x: 320, y: 300), moved: .zero, surface: surface, view: view)
        XCTAssertEqual(touches.pixels(view, screen: 3), CGSize(width: 1920, height: 1800))
    }

    /// Pinching out stops at the whole picture, back in its place.
    func testPinchingOutStopsAtTheWholePicture() {
        let (surface, view) = (CGSize(width: 1280, height: 800), CGSize(width: 640, height: 600))
        var touches = SurfaceTouches()
        touches.zoom(by: 3, around: CGPoint(x: 100, y: 150), moved: .zero, surface: surface, view: view)
        touches.zoom(by: 0.1, around: CGPoint(x: 600, y: 500), moved: .zero, surface: surface, view: view)
        XCTAssertEqual(touches.frame(surface, in: view), CGRect(x: 0, y: 100, width: 640, height: 400))
    }
}

/// A viewer's link as the relay sees it: what got through, and what is still waiting while it stalls.
private final class FakeLink: @unchecked Sendable {
    let lock = NSLock()
    var stalled = true
    var backlog = 0
    var forwarded: [SurfacePacket] = []
}
