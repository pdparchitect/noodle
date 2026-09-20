import CoreImage
import NoodleCore
import XCTest
@testable import NoodleVisionTools

final class VisionToolsTests: XCTestCase {
    private let provider = VisionToolProvider()
    private let context = ToolCallContext(agentID: UUID(), workspace: URL(fileURLWithPath: "/"))
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func call(_ tool: String, image: Data?, arguments: String = "{}") async throws -> [String: Any] {
        var files: [ToolFile] = []
        if let image {
            let url = root.appendingPathComponent(UUID().uuidString)
            try image.write(to: url)
            files = [ToolFile(parameter: "image", access: .read, handle: try FileHandle(forReadingFrom: url))]
        }
        let data = try await provider.call(tool, arguments: Data(arguments.utf8), files: files, context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testManifestAndToolListFollowTheProviderContract() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.id, "vision")
        XCTAssertEqual(provider.manifest.activation, .always)
        let listed = try await provider.tools(context: context)
        let tools = try ToolDescriptor.list(mcp: listed)
        XCTAssertEqual(tools.map(\.name), ["ocr", "classify", "barcodes"])
        for tool in tools {
            XCTAssertEqual(tool.fileParameters, [ToolFileParameter(name: "image", access: .read)], tool.name)
            XCTAssertTrue(tool.retryable, "\(tool.name) only reads, so a timed-out call may be repeated")
            XCTAssertFalse(tool.description.isEmpty)
        }
    }

    func testBarcodesReadsAGeneratedQRCode() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/noodle?id=42".utf8), forKey: "inputMessage")
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let png = try XCTUnwrap(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let result = try await call("barcodes", image: png)
        // Virtualized CI hosts can lack the hardware Vision's detectors start on. Anywhere else a failure is a failure.
        if result["isError"] as? Bool == true, ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Vision could not run on this CI host: \(((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "")")
        }
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let codes = try XCTUnwrap(structured["barcodes"] as? [[String: Any]])
        XCTAssertEqual(codes.first?["payload"] as? String, "https://example.com/noodle?id=42")
        XCTAssertEqual(codes.first?["symbology"] as? String, "QR")
        XCTAssertNotNil(codes.first?["boundingBox"])
    }

    func testBadInputIsAToolErrorNotACrash() async throws {
        for (tool, image) in [("ocr", Data("not an image".utf8) as Data?), ("barcodes", nil), ("unknown", Data())] {
            let result = try await call(tool, image: image)
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
            XCTAssertFalse((((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "").isEmpty, tool)
        }
    }
}
