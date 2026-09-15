import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NoodleWallpaperCore

final class BackgroundDropTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundDropTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFinderImageOwnsItsPreviewAndReleasesItAfterUse() async throws {
        let source = try image(in: directory())
        var file: PreparedBackgroundFile? = try await BackgroundDrop.load(NSItemProvider(object: source as NSURL))
        XCTAssertEqual(file?.kind, .image)
        let preview = try XCTUnwrap(file?.url)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(BackgroundMedia.image(at: preview, index: 0))
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    }

    func testBrowserImageBytesWinOverPageLinkAndHTML() async throws {
        let bytes = try Data(contentsOf: image(in: directory()))
        let provider = NSItemProvider(object: URL(string: "https://example.invalid/page")! as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
            completion(Data("<img src='picture.png'>".utf8), nil); return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil); return nil
        }
        let file = try await BackgroundDrop.load(provider)
        XCTAssertEqual(file.kind, .image)
        XCTAssertNotNil(BackgroundMedia.image(at: file.url, index: 0))
    }

    func testPromisedVideoKeepsMovieInsteadOfPosterAndSurvivesProviderRemoval() async throws {
        let root = try directory(), source = root.appendingPathComponent("clip.mov")
        try await video(at: source)
        let bytes = try Data(contentsOf: image(in: root))
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil); return nil
        }
        provider.registerFileRepresentation(forTypeIdentifier: UTType.quickTimeMovie.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil); return nil
        }
        let file = try await BackgroundDrop.load(provider)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(file.kind, .video)
        let poster = await BackgroundMedia.poster(at: file.url, kind: file.kind)
        XCTAssertNotNil(poster)
    }

    func testDirectRemoteImageAndExtensionlessVideoDownloadIntoOwnedPreviews() async throws {
        let root = try directory(), movie = root.appendingPathComponent("clip.mov")
        try await video(at: movie)
        for (source, mime, kind) in [(try image(in: root), "image/png", BackgroundMediaKind.image),
                                      (movie, "video/quicktime", .video)] {
            let configuration = remoteConfiguration(source: source, mime: mime)
            let provider = NSItemProvider(object: URL(string: "https://example.invalid/download")! as NSURL)
            let file = try await BackgroundDrop.load(provider, configuration: configuration)
            XCTAssertEqual(file.kind, kind)
            let poster = await BackgroundMedia.poster(at: file.url, kind: file.kind)
            XCTAssertNotNil(poster)
        }
    }

    func testBrokenBrowserRepresentationFallsBackToDirectMediaURL() async throws {
        let configuration = remoteConfiguration(source: try image(in: directory()), mime: "image/png")
        let provider = NSItemProvider(object: URL(string: "https://example.invalid/download")! as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, URLError(.fileDoesNotExist)); return nil
        }
        let file = try await BackgroundDrop.load(provider, configuration: configuration)
        XCTAssertEqual(file.kind, .image)
    }

    func testRemoteVideoWithGenericMIMEUsesItsFilename() async throws {
        let source = try directory().appendingPathComponent("clip.mov")
        try await video(at: source)
        let provider = NSItemProvider(object: URL(string: "https://example.invalid/clip.mov")! as NSURL)
        let file = try await BackgroundDrop.load(provider,
            configuration: remoteConfiguration(source: source, mime: "application/octet-stream"))
        XCTAssertEqual(file.kind, .video)
    }

    func testOversizedRemoteMediaIsRejected() async throws {
        let configuration = remoteConfiguration(source: try image(in: directory()), mime: "image/png")
        do {
            _ = try await BackgroundDrop.loadRemote(URL(string: "https://example.invalid/oversized")!, configuration: configuration)
            XCTFail("Accepted a download exceeding the background size limit")
        } catch {}
    }

    func testWebPagesHTTPFailuresAndNonWebSchemesAreRejected() async throws {
        let root = try directory(), page = root.appendingPathComponent("page.html")
        try Data("<html>This is a web page, not media.</html>".utf8).write(to: page)
        let configuration = remoteConfiguration(source: page, mime: "text/html")
        for address in ["https://example.invalid/download", "https://example.invalid/unavailable", "ftp://example.invalid/picture.png"] {
            do {
                _ = try await BackgroundDrop.load(NSItemProvider(object: URL(string: address)! as NSURL), configuration: configuration)
                XCTFail("Accepted \(address)")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertFalse(BackgroundDrop.accepts(NSItemProvider(object: "ordinary text" as NSString)))
    }

    func testFinderVideoPreservesOriginalMedia() async throws {
        let root = try directory(), source = root.appendingPathComponent("clip.mov")
        try await video(at: source)
        let file = try await BackgroundDrop.load(NSItemProvider(object: source as NSURL))
        XCTAssertEqual(file.kind, .video)
        XCTAssertNotEqual(file.url, source)
        XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: source))
    }

    private func remoteConfiguration(source: URL, mime: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundResponseFixture.self]
        configuration.httpAdditionalHeaders = ["X-Test-File": source.path, "X-Test-Mime": mime]
        return configuration
    }

    private func image(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("picture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func video(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 100, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 3)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

private final class BackgroundResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: request.value(forHTTPHeaderField: "X-Test-File")!))
            let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.lastPathComponent == "unavailable" ? 404 : 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": request.value(forHTTPHeaderField: "X-Test-Mime")!,
                    "Content-Length": String(request.url!.lastPathComponent == "oversized" ? BackgroundDrop.maximumBytes + 1 : Int64(data.count))])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
