import CoreGraphics
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NoodleWallpaperCore

/// Paste in a background editor takes what a drop takes: a copied picture, video or Metal shader file, or a
/// copied picture's data. Anything else leaves Paste off.
final class BackgroundPasteTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundPasteTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func shader(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Aurora.metal")
        try ShaderProgramTests.stitchable.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func dataProvider(_ data: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    // MARK: The Mac, which reads the clipboard itself

    func testACopiedShaderFilePastesAsTheShader() async throws {
        let source = try shader(in: directory())
        // Finder puts the file's icon beside the file; the file wins.
        let icon = try dataProvider(png(), type: .tiff)
        let item = try XCTUnwrap(BackgroundPaste.item(fileURLs: [source], providers: [icon]))
        let file = try await BackgroundDrop.load(item)
        XCTAssertEqual(file.kind, .shader)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), ShaderProgramTests.stitchable)
    }

    func testCopiedShaderSourceWithoutAFilePastesAsTheShader() async throws {
        let source = Data(ShaderProgramTests.stitchable.utf8)
        let item = try XCTUnwrap(BackgroundPaste.item(fileURLs: [], providers: [dataProvider(source, type: .metalShader)]))
        let file = try await BackgroundDrop.load(item)
        XCTAssertEqual(file.kind, .shader)
        XCTAssertEqual(try Data(contentsOf: file.url), source)
    }

    func testCopiedPictureDataPastesAsThePicture() async throws {
        let item = try XCTUnwrap(BackgroundPaste.item(fileURLs: [], providers: [dataProvider(png(), type: .png)]))
        let file = try await BackgroundDrop.load(item)
        XCTAssertEqual(file.kind, .image)
        XCTAssertNotNil(BackgroundMedia.image(at: file.url, index: 0))
    }

    func testTextOrACopiedDocumentLeavesPasteOff() throws {
        let document = try directory().appendingPathComponent("Report.pdf")
        try Data("%PDF-1.4".utf8).write(to: document)
        XCTAssertNil(BackgroundPaste.item(fileURLs: [], providers: [NSItemProvider(object: "ordinary text" as NSString)]))
        XCTAssertNil(BackgroundPaste.item(fileURLs: [], providers: []))
        // Not the document's icon in its place.
        XCTAssertNil(BackgroundPaste.item(fileURLs: [document], providers: [try dataProvider(png(), type: .tiff)]))
    }

    // MARK: iPhone and iPad, where the system's Paste control reads the clipboard

    func testPasteControlTakesACopiedShaderFile() async throws {
        let source = try shader(in: directory())
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        XCTAssertTrue(PastedBackground.contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) })
        var pasted: PastedBackground? = try await load(provider)
        let file = try await XCTUnwrap(pasted).prepare()
        XCTAssertEqual(file.kind, .shader)
        let staged = try XCTUnwrap(pasted).file
        pasted = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the staged copy goes with the paste")
    }

    func testPasteControlTakesCopiedPictureData() async throws {
        let file = try await load(dataProvider(png(), type: .png)).prepare()
        XCTAssertEqual(file.kind, .image)
    }

    func testPasteControlIsOffForText() async throws {
        let text = NSItemProvider(object: "ordinary text" as NSString)
        XCTAssertFalse(PastedBackground.contentTypes.contains { text.hasItemConformingToTypeIdentifier($0.identifier) })
        do {
            _ = try await load(text)
            XCTFail("Text pasted as a background")
        } catch {}
    }

    private func load(_ provider: NSItemProvider) async throws -> PastedBackground {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PastedBackground.self) { continuation.resume(with: $0) }
        }
    }
}
