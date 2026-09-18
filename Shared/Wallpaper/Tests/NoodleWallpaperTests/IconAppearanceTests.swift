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
