import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

@MainActor final class AnimatedWallpaperTests: XCTestCase {
    /// A video four times wider than it is tall must fill a tall, narrow window and a wide one,
    /// cropping its overflow rather than leaving bars, and keep filling it as the window resizes.
    func testAVideoFillsTheWholeWindowWhateverItsShape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnimatedWallpaperTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide.mov")
        try await redVideo(at: url, width: 128, height: 32)

        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 400, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: AnimatedWallpaper(url: url, kind: .video, reduceMotion: false)
            .ignoresSafeArea())
        defer { window.close(); window.contentView = nil }
        window.orderFront(nil)

        // Petko's window in #176 was 260 by 789 points.
        for size in [NSSize(width: 400, height: 300), NSSize(width: 260, height: 789), NSSize(width: 900, height: 320)] {
            window.setContentSize(size)
            var uncovered: [String] = []
            let end = ContinuousClock.now + .seconds(5)
            repeat {
                try await Task.sleep(for: .milliseconds(200))
                uncovered = try await uncoveredPoints(window)
            } while !uncovered.isEmpty && ContinuousClock.now < end
            XCTAssertEqual(uncovered, [], "Video bars in a \(Int(size.width))×\(Int(size.height)) window")
        }
    }

    /// The picture follows every change to the view's size at once, not only after the next
    /// layout pass, so a resizing window never shows the canvas around a stale picture.
    func testThePictureFollowsEveryResizeAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnimatedWallpaperTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide.mov")
        try await redVideo(at: url, width: 128, height: 32)

        for kind in [BackgroundMediaKind.video, .dynamicImage] {
            let view = AnimatedWallpaperView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            defer { view.stop() }
            view.configure(url: url, kind: kind, reduceMotion: true)
            view.layoutSubtreeIfNeeded()
            for size in [NSSize(width: 260, height: 789), NSSize(width: 900, height: 320)] {
                view.setFrameSize(size)
                let backing = try XCTUnwrap(view.layer)
                XCTAssertTrue(backing.masksToBounds)
                // The video layer, and the layer that shows a picture.
                let candidates = [backing] + (backing.sublayers ?? [])
                let video = try XCTUnwrap(candidates.compactMap { $0 as? AVPlayerLayer }.first)
                let picture = try XCTUnwrap(candidates.first { !($0 is AVPlayerLayer) && $0.contentsGravity == .resizeAspectFill })
                XCTAssertEqual(video.videoGravity, .resizeAspectFill)
                if kind == .video { XCTAssertNotNil(video.player) }
                for layer in [video, picture] {
                    XCTAssertEqual(backing.convert(layer.bounds, from: layer), view.bounds,
                        "\(kind) \(type(of: layer)) in a \(Int(size.width))×\(Int(size.height)) view")
                }
            }
        }
    }

    /// Points along the edges and the middle of the window where the red video does not show.
    private func uncoveredPoints(_ window: NSWindow) async throws -> [String] {
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width)
        config.height = Int(target.frame.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let (width, height) = (image.width, image.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var uncovered: [String] = []
        // Stay clear of the rounded window corners.
        for fx in [0.06, 0.5, 0.94] {
            for fy in [0.06, 0.25, 0.5, 0.75, 0.94] {
                let x = Int(Double(width - 1) * fx), y = Int(Double(height - 1) * fy)
                let offset = y * width * 4 + x * 4
                let (r, g, b) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                if r < 120 || g > 90 || b > 90 { uncovered.append("(\(fx), \(fy)) rgb(\(r),\(g),\(b))") }
            }
        }
        return uncovered
    }

    private func redVideo(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
            for row in 0..<height {
                for column in 0..<width {
                    let pixelOffset = row * rowBytes + column * 4
                    base[pixelOffset] = 255; base[pixelOffset + 1] = 230; base[pixelOffset + 2] = 20; base[pixelOffset + 3] = 20
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
