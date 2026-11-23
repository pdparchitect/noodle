import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import Noodle

@MainActor final class AttachmentThumbnailTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnails-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A shader sent in a conversation shows a still of what it draws, not a blank file card; one that
    /// does not compile keeps the card.
    func testAShaderFileShowsAStillOfWhatItDraws() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let shader = root.appendingPathComponent("Aurora.metal")
        try """
            #include <metal_stdlib>
            #include <SwiftUI/SwiftUI_Metal.h>
            using namespace metal;
            [[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time) {
                float2 uv = position / size;
                return half4(half3(uv.y, 0.5 + 0.5 * sin(uv.x * 6.0 + time), 1.0 - uv.y), 1.0h);
            }
            """.write(to: shader, atomically: true, encoding: .utf8)
        let rendered = await AttachmentThumbnailCache.shaderStill(for: shader)
        let still = try XCTUnwrap(rendered)
        XCTAssertEqual(still.size, CGSize(width: 520, height: 300))
        // Drawn at a Retina size whatever this screen's scale, as the cache keeps its other thumbnails. The
        // representation reports pixels for this screen, so count the picture's own.
        XCTAssertEqual(still.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 1040, "drawn for a Retina display")

        let broken = root.appendingPathComponent("Broken.metal")
        try "[[ stitchable ]] half4 broken(float2 position) { return nope; }".write(to: broken, atomically: true, encoding: .utf8)
        let brokenStill = await AttachmentThumbnailCache.shaderStill(for: broken)
        XCTAssertNil(brokenStill)
        let text = root.appendingPathComponent("Notes.txt")
        try "half4 not a shader".write(to: text, atomically: true, encoding: .utf8)
        let textStill = await AttachmentThumbnailCache.shaderStill(for: text)
        XCTAssertNil(textStill)
    }

    /// Scrolling back to a picture after memory was reclaimed reads a small copy, not the original.
    func testAThumbnailIsDecodedOnceAtTheSizeItIsShown() throws {
        let original = root.appendingPathComponent("photo.png"), cache = root.appendingPathComponent("Cache")
        try writePNG(width: 2_400, height: 1_200, to: original)
        let decodes = AttachmentThumbnailCache.decodes
        let first = try XCTUnwrap(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        let pixels = try XCTUnwrap(first.representations.first)
        XCTAssertLessThanOrEqual(max(pixels.pixelsWide, pixels.pixelsHigh), 600)
        XCTAssertNotNil(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        XCTAssertEqual(AttachmentThumbnailCache.decodes, decodes + 1)

        // A changed original gets a new thumbnail.
        try FileManager.default.removeItem(at: original)
        try writePNG(width: 1_200, height: 2_400, to: original)
        let second = try XCTUnwrap(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        XCTAssertEqual(AttachmentThumbnailCache.decodes, decodes + 2)
        let size = try XCTUnwrap(second.representations.first)
        XCTAssertGreaterThan(size.pixelsHigh, size.pixelsWide)
    }

    /// A card is shown no wider than an image preview, so its picture is decoded no larger.
    func testACardPictureIsDecodedAtTheSizeItIsShown() throws {
        let file = root.appendingPathComponent("tab.png")
        try writePNG(width: 2_400, height: 1_200, to: file)
        let card = try XCTUnwrap(AttachmentThumbnailCache.cardThumbnail(from: Data(contentsOf: file)))
        let pixels = try XCTUnwrap(card.representations.first)
        XCTAssertLessThanOrEqual(max(pixels.pixelsWide, pixels.pixelsHigh), AttachmentThumbnailCache.thumbnailPixels)
    }

    /// Every picture scrolled past is remembered, so what is remembered must have a limit; the
    /// oldest unseen go first.
    func testRememberedThumbnailsStayWithinAMemoryLimit() throws {
        let cache = AttachmentThumbnailCache.shared
        cache.removeAllObjects()
        defer { cache.removeAllObjects() }
        func picture() throws -> NSImage {
            let image = NSImage(size: NSSize(width: 2_000, height: 2_000))
            image.addRepresentation(try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_000, pixelsHigh: 2_000,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)))
            return image
        }
        let keys = (0..<40).map { root.appendingPathComponent("\($0).png") as NSURL }
        cache.setObject(try picture(), forKey: keys[0])
        cache.setObject(try picture(), forKey: keys[1])
        for key in keys.dropFirst(2) {
            XCTAssertNotNil(cache.object(forKey: keys[0]))
            cache.setObject(try picture(), forKey: key)
        }
        XCTAssertNotNil(cache.object(forKey: keys[0]), "A picture still being looked at stays")
        XCTAssertNil(cache.object(forKey: keys[1]))
        XCTAssertNotNil(cache.object(forKey: keys[39]))
    }

    /// A bubble is rebuilt many times while scrolling; its file is opened once to see if it is a picture.
    func testWhetherAFileIsAPictureIsReadOnce() throws {
        let file = root.appendingPathComponent("unlabelled.bin")
        try writePNG(width: 4, height: 4, to: file)
        let reads = AttachmentThumbnailCache.headerReads
        XCTAssertTrue(AttachmentThumbnailCache.isImage(file))
        XCTAssertTrue(AttachmentThumbnailCache.isImage(file))
        XCTAssertEqual(AttachmentThumbnailCache.headerReads, reads + 1)
    }
}
