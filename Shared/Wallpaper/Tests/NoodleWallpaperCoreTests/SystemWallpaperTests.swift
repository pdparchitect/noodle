import AppKit
import XCTest
@testable import NoodleWallpaperCore

final class SystemWallpaperTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SystemWallpaperTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeImage(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func writeDescriptor(_ name: String, identifier: String, in catalogue: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["mobileAssetID": identifier], format: .xml, options: 0)
        try data.write(to: catalogue.appendingPathComponent("\(name).madesktop"))
    }

    func testOffersBundledImagesAndOnlyDownloadedDescriptors() throws {
        let catalogue = try directory(), downloads = try directory()
        try writeImage(catalogue.appendingPathComponent("Sonoma.heic"))
        try writeImage(catalogue.appendingPathComponent(".thumbnails/Sonoma.heic"))
        try writeImage(catalogue.appendingPathComponent("Solid Colors/Black.png"))
        try writeDescriptor("The Lake", identifier: "The Lake", in: catalogue)
        try writeDescriptor("The Beach", identifier: "The Beach", in: catalogue)
        try writeImage(downloads.appendingPathComponent("The Lake.heic"))

        let wallpapers = SystemWallpaper.available(catalogue: catalogue, downloads: downloads, aerials: try directory())

        XCTAssertEqual(wallpapers.map(\.name), ["Sonoma", "The Lake"])
        XCTAssertEqual(wallpapers[0].url.lastPathComponent, "Sonoma.heic")
        XCTAssertEqual(wallpapers[0].thumbnailURL?.path, catalogue.appendingPathComponent(".thumbnails/Sonoma.heic").path)
        XCTAssertEqual(wallpapers[1].url.path, downloads.appendingPathComponent("The Lake.heic").path)
        XCTAssertNil(wallpapers[1].thumbnailURL)
    }

    func testLeavesOutPartialDownloadsAndEscapingIdentifiers() throws {
        let catalogue = try directory(), downloads = try directory()
        try writeDescriptor("Partial", identifier: "Partial", in: catalogue)
        try Data("not an image".utf8).write(to: downloads.appendingPathComponent("Partial.heic"))
        try writeDescriptor("Escape", identifier: "../outside", in: catalogue)
        try writeImage(downloads.deletingLastPathComponent().appendingPathComponent("outside.heic"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: downloads.deletingLastPathComponent().appendingPathComponent("outside.heic"))
        }
        try Data("junk".utf8).write(to: catalogue.appendingPathComponent("Broken.madesktop"))

        XCTAssertEqual(SystemWallpaper.available(catalogue: catalogue, downloads: downloads, aerials: try directory()), [])
    }

    func testOffersHiddenCatalogueWallpapersAndDownloadsWithoutADescriptor() throws {
        let catalogue = try directory(), downloads = try directory(), aerials = try directory()
        let horizon = catalogue.appendingPathComponent(".wallpapers/Horizon")
        try writeImage(horizon.appendingPathComponent("Horizon.heic"))
        try writeImage(horizon.appendingPathComponent("Horizon Thumbnail@2x.png"))
        try writeImage(horizon.appendingPathComponent("Horizon Thumbnail.png"))
        let graphic = catalogue.appendingPathComponent(".wallpapers/Graphic")
        try FileManager.default.createDirectory(at: graphic, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: graphic.appendingPathComponent("Graphic Landscape.mov"))
        try writeImage(downloads.appendingPathComponent("Retired.heic"))
        try writeImage(downloads.appendingPathComponent("Photo.jpg"))

        let wallpapers = SystemWallpaper.available(catalogue: catalogue, downloads: downloads, aerials: aerials)

        XCTAssertEqual(wallpapers.map(\.name), ["Graphic Landscape", "Horizon", "Photo", "Retired"])
        XCTAssertEqual(wallpapers[1].thumbnailURL?.lastPathComponent, "Horizon Thumbnail@2x.png")
        XCTAssertNil(wallpapers[0].thumbnailURL)
    }

    func testOffersDownloadedAerialsByTheirManifestName() throws {
        let aerials = try directory()
        let videos = aerials.appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: videos.appendingPathComponent("A1.mov"))
        try Data("video".utf8).write(to: videos.appendingPathComponent("B2.mov"))
        try Data().write(to: videos.appendingPathComponent("Empty.mov"))
        try Data("text".utf8).write(to: videos.appendingPathComponent("notes.txt"))
        try writeImage(aerials.appendingPathComponent("thumbnails/A1.png"))
        let manifest = ["assets": [["id": "A1", "accessibilityLabel": "Grand Canyon"], ["id": "Z9", "accessibilityLabel": "Not Downloaded"]]]
        try FileManager.default.createDirectory(at: aerials.appendingPathComponent("manifest"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: aerials.appendingPathComponent("manifest/entries.json"))
        let empty = try directory()

        let wallpapers = SystemWallpaper.available(catalogue: empty, downloads: empty, aerials: aerials)

        XCTAssertEqual(wallpapers.map(\.name), ["Aerial", "Grand Canyon"])
        XCTAssertEqual(wallpapers[1].url.lastPathComponent, "A1.mov")
        XCTAssertEqual(wallpapers[1].thumbnailURL?.lastPathComponent, "A1.png")
        XCTAssertNil(wallpapers[0].thumbnailURL)
    }

    func testMissingFoldersYieldNoWallpapers() throws {
        let missing = try directory().appendingPathComponent("missing")
        XCTAssertEqual(SystemWallpaper.available(catalogue: missing, downloads: missing, aerials: missing), [])
    }
}
