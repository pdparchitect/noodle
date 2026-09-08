import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import NoodleCore

final class BackgroundMediaTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-media-tests-\(UUID())")
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testLegacyBackgroundDecodesWithoutMediaKind() throws {
        let old = Data("{\"imageFilename\":\"\(UUID()).jpg\"}".utf8)
        let decoded = try JSONDecoder().decode(ConversationBackground.self, from: old)
        XCTAssertNil(decoded.mediaKind)
        XCTAssertFalse(decoded.isDefault)
    }

    func testHEICFramesPersistAndTemporaryCopyIsReleased() async throws {
        let url = root.appendingPathComponent("dynamic.heic")
        try imageFixture(url, type: .heic, count: 3)
        XCTAssertEqual(BackgroundMedia.frameCount(at: url), 3)
        let original = try Data(contentsOf: url)
        var prepared: PreparedBackgroundFile? = try await PreparedBackgroundFile.prepare(url)
        XCTAssertEqual(prepared?.kind, .dynamicImage)
        let temporary = try XCTUnwrap(prepared?.url)
        let bot = try repository.createAgent(named: "Bot")
        let group = try repository.createGroup(named: "Group", participantIDs: [bot.agent.id], existingAgents: [bot.agent])
        for id in [bot.conversation.id, group.id] {
            let saved = try repository.setBackground(conversationID: id, file: XCTUnwrap(prepared))
            let stored = try XCTUnwrap(repository.backgroundImageURL(saved, conversationID: id))
            XCTAssertEqual(try Data(contentsOf: stored), original)
            XCTAssertEqual(try repository.loadBackground(conversationID: id), saved)
            XCTAssertNotNil(BackgroundMedia.image(at: stored, index: 2))
            try repository.setBackground(conversationID: id, preset: .ocean)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        }
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testStillHEICRemainsStill() async throws {
        let url = root.appendingPathComponent("photo.heic")
        try imageFixture(url, type: .heic, count: 1)
        let file = try await PreparedBackgroundFile.prepare(url)
        XCTAssertEqual(file.kind, .image)
        XCTAssertEqual(file.url.pathExtension, "jpg")
        XCTAssertNotNil(BackgroundMedia.image(at: file.url, index: 0))
    }

    func testVideoPersistsIndependentlyAndHasPoster() async throws {
        let url = root.appendingPathComponent("clip.mov")
        try await videoFixture(url)
        let file = try await PreparedBackgroundFile.prepare(url)
        XCTAssertEqual(file.kind, .video)
        let poster = await BackgroundMedia.poster(at: file.url, kind: .video)
        XCTAssertNotNil(poster)
        XCTAssertEqual(BackgroundMedia.videoAsset(at: file.url).referenceRestrictions, .forbidAll)
        let bot = try repository.createAgent(named: "Bot")
        let background = try repository.setBackground(conversationID: bot.conversation.id, file: file)
        try FileManager.default.removeItem(at: url)
        let stored = try XCTUnwrap(repository.backgroundImageURL(background, conversationID: bot.conversation.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try repository.loadBackground(conversationID: bot.conversation.id).mediaKind, .video)
        try repository.setBackground(conversationID: bot.conversation.id, preset: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    func testUnsupportedFilesAndManagedPaths() async throws {
        for name in ["broken.mov", "movie.m3u8", "fake.heic"] {
            let url = root.appendingPathComponent(name)
            try Data("Not media".utf8).write(to: url)
            do { _ = try await PreparedBackgroundFile.prepare(url); XCTFail("Accepted \(name)") } catch {}
        }
        for name in ["../../\(UUID()).mov", "clip.mov", "\(UUID()).m3u8", "\(UUID()).heic/../secret"] {
            XCTAssertNil(repository.backgroundImageURL(.init(imageFilename: name, mediaKind: .video), conversationID: UUID()))
        }
        do {
            _ = try await PreparedBackgroundFile.prepare(URL(string: "https://example.com/movie.mov")!)
            XCTFail("Accepted remote URL")
        } catch {}
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

    private func videoFixture(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
