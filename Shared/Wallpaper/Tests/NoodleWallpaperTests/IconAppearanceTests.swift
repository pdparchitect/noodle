import AppKit
import XCTest
@testable import NoodleWallpaper

final class IconAppearanceTests: XCTestCase {
    func testPaletteKeepsIndexesInRangeAndWrapsBotSeeds() {
        XCTAssertEqual(IconPalette.gradients.count, 6)
        for index in 0..<6 {
            XCTAssertEqual(IconPalette.index(for: index), index)
            XCTAssertEqual(IconPalette.clamped(index), index)
        }
        // The rule Noodle's bot avatars have always used: abs(seed) % 6.
        for seed in [6, 7, 13, -1, -7, 1_000_003, -1_000_003] {
            XCTAssertEqual(IconPalette.index(for: seed), abs(seed) % 6, "seed \(seed)")
        }
        XCTAssertTrue((0..<6).contains(IconPalette.index(for: .min)), "Int.min must not trap")
        XCTAssertEqual(IconPalette.index(for: .max), Int.max % 6)
        // The rule Browser and Computer icons have always used.
        XCTAssertEqual(IconPalette.clamped(-3), 0)
        XCTAssertEqual(IconPalette.clamped(9), 5)
    }

    func testPNGEncodingScalesToFitAndRefusesOversizeOutput() throws {
        let prepared = try IconImage.prepare(image(width: 2048, height: 1024), encoding: .png(maxBytes: 2 * 1024 * 1024))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: prepared))
        XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [512, 256])
        XCTAssertEqual(Array(prepared.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "Browser and Computer store PNG")
        XCTAssertThrowsError(try IconImage.prepare(image(width: 64, height: 64), encoding: .png(maxBytes: 10))) {
            XCTAssertEqual($0 as? IconImageError, .encodedTooLarge)
        }
    }

    func testJPEGEncodingMatchesNoodleBotIcons() throws {
        let prepared = try IconImage.prepare(image(width: 1024, height: 2048), encoding: .jpeg(quality: 0.86))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: prepared))
        XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [256, 512])
        XCTAssertEqual(Array(prepared.prefix(3)), [0xFF, 0xD8, 0xFF], "Noodle stores JPEG")
    }

    /// A wide camera frame keeps its middle, square, as the phone's camera crops a picture.
    func testACameraPhotoKeepsTheMiddleOfTheFrameAsASquare() throws {
        // Red, green and blue thirds: only the green middle may survive.
        let width = 1200, height = 400
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (index, colour) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            context.setFillColor(colour)
            context.fill(CGRect(x: index * 400, y: 0, width: 400, height: height))
        }
        let prepared = try IconImage.photo(try XCTUnwrap(context.makeImage()), encoding: .png(maxBytes: 2 * 1024 * 1024))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: prepared))
        XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [400, 400])
        for (x, y) in [(2, 2), (397, 2), (200, 200), (2, 397), (397, 397)] {
            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(colour.greenComponent, 0.9, "(\(x), \(y))")
            XCTAssertLessThan(colour.redComponent + colour.blueComponent, 0.1, "(\(x), \(y))")
        }
    }

    /// Take Photo waits for the camera: there is nothing to take until its first frame arrives.
    func testTheCameraIsLiveFromItsFirstFrame() throws {
        let latest = CameraPhotoSheet.LatestFrame()
        XCTAssertNil(latest.image())
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try XCTUnwrap(buffer)
        XCTAssertTrue(latest.keep(frame), "the first frame makes the camera live")
        XCTAssertFalse(latest.keep(frame), "later frames change nothing")
        XCTAssertNotNil(latest.image())
    }

    func testRejectsUnreadableAndOversizeSources() throws {
        XCTAssertThrowsError(try IconImage.prepare(Data("not an image".utf8), encoding: .jpeg(quality: 0.86))) {
            XCTAssertEqual($0 as? IconImageError, .invalidImage)
        }
        let huge = Data(count: IconImage.maxSourceBytes + 1)
        XCTAssertThrowsError(try IconImage.prepare(huge, encoding: .png(maxBytes: .max))) {
            XCTAssertEqual($0 as? IconImageError, .sourceTooLarge)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IconAppearanceTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("icon.png")
        try image(width: 32, height: 32).write(to: file)
        XCTAssertNoThrow(try IconImage.load(file, encoding: .png(maxBytes: 2 * 1024 * 1024)))
    }

    private func image(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
