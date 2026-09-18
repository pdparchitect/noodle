import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

@MainActor final class SystemWallpaperSheetTests: XCTestCase {
    /// The dialog must actually draw each wallpaper's thumbnail, not only its name.
    func testGridDrawsThumbnails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SystemWallpaperSheetTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = directory.appendingPathComponent("red.png")
        try solid(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)).write(to: red)
        let wallpapers = (1...6).map {
            SystemWallpaper(name: "Wallpaper \($0)", url: directory.appendingPathComponent("\($0).heic"), thumbnailURL: red)
        }

        let bitmap = try await render(SystemWallpaperSheet(wallpapers: wallpapers, reload: { wallpapers }) { _ in })

        // The first cell starts inside the 20-point grid padding, below the 53-point header.
        let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(60 * scale(bitmap)), y: Int(100 * scale(bitmap)))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8, "First thumbnail was not drawn: \(pixel)")
        XCTAssertLessThan(pixel.greenComponent, 0.3, "First thumbnail was not drawn: \(pixel)")
    }

    func testSettingsLinkOpensTheWallpaperPane() throws {
        let url = SystemWallpaperSheet.settingsURL
        XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        XCTAssertEqual(NSWorkspace.shared.urlForApplication(toOpen: url)?.lastPathComponent, "System Settings.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions/Wallpaper.appex"),
            "The Wallpaper settings pane moved; update SystemWallpaperSheet.settingsURL")
    }

    /// Set NOODLE_WALLPAPER_SHEET_SNAPSHOT to a PNG path to inspect this Mac's real dialog.
    func testSnapshotOfInstalledWallpapers() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_WALLPAPER_SHEET_SNAPSHOT"] else {
            throw XCTSkip("Snapshot path not requested")
        }
        let bitmap = try await render(SystemWallpaperSheet(wallpapers: SystemWallpaper.available()) { _ in })
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func scale(_ bitmap: NSBitmapImageRep) -> CGFloat { CGFloat(bitmap.pixelsWide) / bitmap.size.width }

    private func render(_ sheet: SystemWallpaperSheet) async throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: sheet.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // Thumbnails decode off the main thread and arrive over a few run loop turns.
        try await Task.sleep(for: .seconds(1))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func solid(_ colour: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<32 { for y in 0..<32 { bitmap.setColor(colour, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
