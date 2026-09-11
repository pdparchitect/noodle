import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP
@testable import NoodleMCP

final class MCPIconTests: XCTestCase {
    private let endpoint = URL(string: "https://service.invalid/mcp")!

    override func setUp() {
        IconFixtureProtocol.reset()
    }

    override func tearDown() {
        IconFixtureProtocol.reset()
    }

    func testSupportedImagesBecomeSmallPNGThumbnailsWithTheirAspectRatio() throws {
        for type in [UTType.png, .jpeg] {
            let original = try image(width: 128, height: 64, type: type)
            let thumbnail = try XCTUnwrap(MCPIcon.thumbnail(original))
            try assertPNG(thumbnail, width: 64, height: 32)
            XCTAssertNotEqual(thumbnail, original)
        }
        let portrait = try XCTUnwrap(MCPIcon.thumbnail(image(width: 32, height: 128)))
        try assertPNG(portrait, width: 16, height: 64)
    }

    func testMalformedUnsupportedAndOversizedImagesAreRejected() throws {
        for data in [Data(), Data("not an image".utf8), try image(type: .gif)] {
            XCTAssertNil(MCPIcon.thumbnail(data))
        }
        // A decodable image padded beyond the byte limit must still be rejected.
        var oversized = try image()
        oversized.append(Data(repeating: 0, count: 131_073 - oversized.count))
        XCTAssertNil(MCPIcon.thumbnail(oversized))
    }

    func testImageDimensionLimitAcceptsBoundaryAndRejectsEitherOversizedDimension() throws {
        XCTAssertNotNil(MCPIcon.thumbnail(try image(width: 4096, height: 1)))
        XCTAssertNil(MCPIcon.thumbnail(try image(width: 4097, height: 1)))
        XCTAssertNil(MCPIcon.thumbnail(try image(width: 1, height: 4097)))
    }

    func testPNGAndJPEGDataURIsAreNormalized() async throws {
        for type in [UTType.png, .jpeg] {
            let icon = Icon(src: "data:\(type.preferredMIMEType!);base64," + (try image(type: type)).base64EncodedString())
            let loaded = await load([icon])
            try assertPNG(XCTUnwrap(loaded), width: 64, height: 32)
        }
    }

    func testInvalidIconFallsBackToNextUsableCandidate() async throws {
        let valid = try dataIcon()
        let invalidSources = [
            "data:image/png;base64,%%%",
            "data:image/jpeg;base64," + Data("not a JPEG".utf8).base64EncodedString(),
            "data:image/png;base64," + String(repeating: "A", count: 180_001),
            "data:image/svg+xml;base64," + Data("<svg/>".utf8).base64EncodedString()
        ]
        for source in invalidSources {
            let loaded = await load([Icon(src: source), valid])
            try assertPNG(XCTUnwrap(loaded), width: 64, height: 32)
        }
    }

    func testUntrustedURLsAreSkippedBeforeUsingEmbeddedFallback() async throws {
        let valid = try dataIcon()
        IconFixtureProtocol.reset(data: try image())
        for source in ["https://other.invalid/noodle-test-icon.png", "https://service.invalid:444/noodle-test-icon.png",
                       "http://service.invalid/noodle-test-icon.png", "file:///tmp/noodle-test-icon.png",
                       "ftp://service.invalid/noodle-test-icon.png"] {
            let loaded = await load([Icon(src: source), valid])
            try assertPNG(XCTUnwrap(loaded), width: 64, height: 32)
        }
        XCTAssertTrue(IconFixtureProtocol.requests.isEmpty, "Untrusted artwork must be rejected before a request is sent")
    }

    func testSameOriginDownloadUsesAnAnonymousRequestAndProducesAPNG() async throws {
        IconFixtureProtocol.reset(data: try image(type: .jpeg))
        let source = "https://service.invalid/noodle-test-icon.png"
        let loaded = await load([Icon(src: source)])
        try assertPNG(XCTUnwrap(loaded), width: 64, height: 32)
        let requests = IconFixtureProtocol.requests
        XCTAssertEqual(requests.count, 1, "The local protocol fixture must intercept the download")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, source)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testFailedAndOversizedDownloadsFallBackToEmbeddedArtwork() async throws {
        let remote = Icon(src: "https://service.invalid/noodle-test-icon.png")
        // Use a portrait fallback so accepting a rejected landscape response cannot pass.
        let fallback = try dataIcon(width: 32, height: 128)
        let original = try image()
        let cases: [(Int, Data, URLError?)] = [
            (404, original, nil),
            (302, original, nil),
            (200, Data("corrupt image".utf8), nil),
            (200, Data(repeating: 0, count: 131_073), nil),
            (200, Data(), URLError(.notConnectedToInternet))
        ]
        for (status, data, error) in cases {
            IconFixtureProtocol.reset(status: status, data: data, error: error)
            let loaded = await load([remote, fallback])
            try assertPNG(XCTUnwrap(loaded), width: 16, height: 64)
            XCTAssertEqual(IconFixtureProtocol.requests.count, 1)
        }
    }

    func testOnlyFirstThreeCandidatesAreConsidered() async throws {
        let invalid = Icon(src: "data:image/png;base64,invalid")
        let valid = try dataIcon()
        let third = await load([invalid, invalid, valid])
        XCTAssertNotNil(third)
        let fourth = await load([invalid, invalid, invalid, valid])
        XCTAssertNil(fourth)
        let empty = await load([])
        XCTAssertNil(empty)
    }

    private func dataIcon(width: Int = 128, height: Int = 64) throws -> Icon {
        Icon(src: "data:image/png;base64," + (try image(width: width, height: height)).base64EncodedString())
    }

    private func load(_ icons: [Icon]) async -> Data? {
        await MCPIcon.load(icons, endpoint: endpoint, sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IconFixtureProtocol.self]
            return configuration
        })
    }

    private func image(width: Int = 128, height: Int = 64, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func assertPNG(_ data: Data, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, file: file, line: line)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(decoded.width, width, file: file, line: line)
        XCTAssertEqual(decoded.height, height, file: file, line: line)
    }
}

/// Intercepts only this suite's uniquely named fixture URLs, including rejected origins.
private final class IconFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var status = 200
    private static var data = Data()
    private static var error: URLError?

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func reset(status: Int = 200, data: Data = Data(), error: URLError? = nil) {
        lock.withLock {
            recorded = []
            self.status = status
            self.data = data
            self.error = error
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.lastPathComponent == "noodle-test-icon.png"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data, error) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.status, Self.data, Self.error)
        }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
