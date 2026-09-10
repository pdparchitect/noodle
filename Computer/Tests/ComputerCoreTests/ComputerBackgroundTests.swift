import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import ComputerCore

final class ComputerBackgroundTests: XCTestCase {
    private var root: URL!
    private var library: ComputerLibrary!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("computer-background-tests-\(UUID())")
        library = try ComputerLibrary(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func commit(_ file: PreparedBackgroundFile? = nil) throws -> Computer {
        var computer = ComputerTemplate.shell.makeComputer(name: "Background fixture")
        var appearance = ComputerAppearance()
        appearance.backgroundFile = file
        computer.appearance = appearance
        try FileManager.default.createDirectory(at: library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        return try library.commit(computer)
    }

    func testLegacyEmbeddedImageAndPresetStillDecode() throws {
        var computer = try commit()
        let url = root.appendingPathComponent("legacy.png")
        try imageFixture(url, type: .png, count: 1)
        computer.appearance?.backgroundImage = try Data(contentsOf: url)
        computer.appearance?.backgroundPreset = "ocean"
        computer = try library.save(computer)
        let decoded = try XCTUnwrap(library.load().first)
        XCTAssertEqual(decoded, computer)
        XCTAssertNil(decoded.appearance?.backgroundFilename)
        XCTAssertNil(decoded.appearance?.backgroundMediaKind)
        XCTAssertNotNil(decoded.appearance?.background.imageFilename)
        XCTAssertNotNil(BackgroundMedia.image(data: try XCTUnwrap(decoded.appearance?.backgroundImage)))
    }

    func testMultiFrameHEICCommitReloadReplaceAndCleanup() async throws {
        let url = root.appendingPathComponent("dynamic.heic")
        try imageFixture(url, type: .heic, count: 3)
        let original = try Data(contentsOf: url)
        var file: PreparedBackgroundFile? = try await PreparedBackgroundFile.prepare(url)
        let temporary = try XCTUnwrap(file?.url)
        var computer = try commit(file)
        XCTAssertNil(computer.appearance?.backgroundFile)
        XCTAssertEqual(computer.appearance?.backgroundMediaKind, .dynamicImage)
        let stored = try XCTUnwrap(computer.appearance?.backgroundURL(in: library.directory(for: computer.id)))
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try Data(contentsOf: stored), original)
        XCTAssertEqual(BackgroundMedia.frameCount(at: stored), 3)
        XCTAssertNotNil(BackgroundMedia.image(at: stored, index: 2))
        XCTAssertEqual(try library.load().first, computer)
        computer.appearance = ComputerAppearance()
        computer.appearance?.backgroundPreset = "sunset"
        computer = try library.save(computer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try library.load().first, computer)
    }

    func testVideoFormatsPersistOutsideMetadataAndHavePosters() async throws {
        for ext in ["mov", "mp4", "m4v"] {
            let url = root.appendingPathComponent("import.\(ext)")
            try await videoFixture(url, type: ext == "mov" ? .mov : .mp4)
            let file = try await PreparedBackgroundFile.prepare(url)
            XCTAssertEqual(file.kind, .video)
            var computer = try commit()
            computer.appearance?.backgroundFile = file
            computer = try library.save(computer)
            let stored = try XCTUnwrap(computer.appearance?.backgroundURL(in: library.directory(for: computer.id)))
            try FileManager.default.removeItem(at: url)
            let poster = await BackgroundMedia.poster(at: stored, kind: .video)
            XCTAssertNotNil(poster)
            XCTAssertEqual(BackgroundMedia.videoAsset(at: stored).referenceRestrictions, .forbidAll)
            let json = try Data(contentsOf: library.directory(for: computer.id).appendingPathComponent("computer.json"))
            XCTAssertLessThan(json.count, 4096)
            XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(file.url.path))
            XCTAssertTrue(try library.load().contains(computer))
        }
    }

    func testStillImagesAndPhotosUseSharedConversion() async throws {
        for type in [UTType.png, .jpeg, .heic] {
            let url = root.appendingPathComponent("photo.\(type.preferredFilenameExtension!)")
            try imageFixture(url, type: type, count: 1)
            let file = try await PreparedBackgroundFile.prepare(url)
            XCTAssertEqual(file.kind, .image)
            XCTAssertEqual(file.url.pathExtension, "jpg")
            XCTAssertNotNil(BackgroundMedia.image(at: file.url, index: 0))
            let photo = try PreparedBackgroundFile.prepare(imageData: Data(contentsOf: url))
            XCTAssertEqual(photo.kind, .image)
            XCTAssertEqual(try Data(contentsOf: photo.url), try BackgroundMedia.jpegData(from: Data(contentsOf: url)))
        }
    }

    func testCancelledDraftReleasesMediaWithoutChangingLibrary() async throws {
        let computer = try commit()
        let source = root.appendingPathComponent("draft.heic")
        try imageFixture(source, type: .heic, count: 2)
        var draft = computer.appearance!
        draft.backgroundFile = try await PreparedBackgroundFile.prepare(source)
        let temporary = try XCTUnwrap(draft.backgroundFile?.url)
        // Preset selection or closing the outer editor releases the owned draft.
        draft = ComputerAppearance()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try library.load().first, computer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFailedReplacementRetainsPreviousBackground() async throws {
        let source = root.appendingPathComponent("photo.png")
        try imageFixture(source, type: .png, count: 1)
        let first = try await PreparedBackgroundFile.prepare(source)
        let computer = try commit(first)
        let old = try XCTUnwrap(computer.appearance?.backgroundURL(in: library.directory(for: computer.id)))
        let replacement = try await PreparedBackgroundFile.prepare(source)
        try FileManager.default.removeItem(at: replacement.url)
        var edited = computer
        edited.appearance?.backgroundFile = replacement
        XCTAssertThrowsError(try library.save(edited))
        XCTAssertEqual(try library.load().first, computer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path).count, 1)
    }

    func testInvalidFormatsLimitsAndManagedPaths() async throws {
        for name in ["broken.mov", "playlist.m3u8", "fake.heic"] {
            let url = root.appendingPathComponent(name)
            try Data("Not media".utf8).write(to: url)
            do { _ = try await PreparedBackgroundFile.prepare(url); XCTFail("Accepted \(name)") } catch {}
        }
        let oversized = root.appendingPathComponent("large.mp4")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()
        do { _ = try await PreparedBackgroundFile.prepare(oversized); XCTFail("Accepted oversized video") } catch {}
        do { _ = try PreparedBackgroundFile.prepare(imageData: Data(repeating: 0, count: 50 * 1024 * 1024 + 1)); XCTFail("Accepted oversized photo") } catch {}
        for name in ["../../\(UUID()).mov", "clip.mov", "\(UUID()).m3u8", "\(UUID()).heic/../secret"] {
            var appearance = ComputerAppearance()
            appearance.backgroundFilename = name
            appearance.backgroundMediaKind = .video
            XCTAssertThrowsError(try appearance.validate())
            XCTAssertNil(appearance.backgroundURL(in: root))
        }
        do { _ = try await PreparedBackgroundFile.prepare(URL(string: "https://example.com/video.mov")!); XCTFail("Accepted remote URL") } catch {}
    }

    private func imageFixture(_ url: URL, type: UTType, count: Int) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        for index in 0..<count {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(count), green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func videoFixture(_ url: URL, type: AVFileType = .mov) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 15), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
