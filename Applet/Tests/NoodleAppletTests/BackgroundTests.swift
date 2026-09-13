import AppKit
import NoodleWallpaperCore
import XCTest

@testable import NoodleApplet

final class BackgroundTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppletBackgroundTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor func testPresetAndDefaultSurviveRelaunch() async throws {
        let store = AppletBackgroundStore(root: root)
        XCTAssertTrue(store.background.isDefault)
        try await store.apply(ConversationBackground(preset: .ocean))
        let reopened = AppletBackgroundStore(root: root)
        XCTAssertEqual(reopened.background.preset, .ocean)
        XCTAssertNil(reopened.imageURL)
        try await reopened.apply(ConversationBackground())
        XCTAssertTrue(AppletBackgroundStore(root: root).background.isDefault)
    }

    @MainActor func testImportOwnsCopyAndReplacementRemovesOldMedia() async throws {
        let store = AppletBackgroundStore(root: root)
        var file: PreparedBackgroundFile? = try imageFixture()
        let temporary = try XCTUnwrap(file?.url)
        let expected = try Data(contentsOf: temporary)
        try await store.apply(ConversationBackground(), file: file)
        let saved = try XCTUnwrap(store.imageURL)
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: saved), expected)
        let reopened = AppletBackgroundStore(root: root)
        XCTAssertEqual(reopened.background, store.background)
        XCTAssertEqual(reopened.background.mediaKind, .image)
        XCTAssertEqual(reopened.imageURL, saved)
        try await reopened.apply(ConversationBackground(preset: .forest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertNil(reopened.imageURL)
    }

    @MainActor func testFailedSaveKeepsPreviousBackgroundAndRemovesNewCopy() async throws {
        let store = AppletBackgroundStore(root: root)
        try await store.apply(ConversationBackground(), file: imageFixture())
        let previous = store.background
        let saved = try XCTUnwrap(store.imageURL)
        let metadata = root.appendingPathComponent("Background.json")
        try FileManager.default.removeItem(at: metadata)
        // A directory at the metadata path forces the atomic write to fail.
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        do {
            try await store.apply(ConversationBackground(), file: imageFixture())
            XCTFail("Save should fail")
        } catch {}
        XCTAssertEqual(store.background, previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Backgrounds").path), [saved.lastPathComponent])
    }

    @MainActor func testMissingMalformedAndUnsafeMediaFallBackToDefault() throws {
        let metadata = root.appendingPathComponent("Background.json")
        for name in ["missing.jpg", "../outside.jpg", "/outside.jpg", ".", ".."] {
            try JSONEncoder().encode(ConversationBackground(imageFilename: name))
                .write(to: metadata, options: .atomic)
            let store = AppletBackgroundStore(root: root)
            XCTAssertTrue(store.background.isDefault, name)
            XCTAssertNil(store.imageURL)
        }
        try Data("invalid".utf8).write(to: metadata)
        XCTAssertTrue(AppletBackgroundStore(root: root).background.isDefault)
    }

    private func imageFixture() throws -> PreparedBackgroundFile {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16,
            pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 0.1, green: 0.6, blue: 0.65, alpha: 1)
        for y in 0..<16 {
            for x in 0..<16 { bitmap.setColor(color, atX: x, y: y) }
        }
        return try PreparedBackgroundFile.prepare(imageData: XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }
}
