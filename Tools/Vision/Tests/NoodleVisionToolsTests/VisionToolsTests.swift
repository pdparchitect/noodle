import CoreImage
import ImageIO
import NoodleCore
import UniformTypeIdentifiers
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

    private func call(_ tool: String, image: Data?, arguments: String = "{}", output: URL? = nil) async throws -> [String: Any] {
        var files: [ToolFile] = []
        if let image {
            let url = root.appendingPathComponent(UUID().uuidString)
            try image.write(to: url)
            files = [ToolFile(parameter: "image", access: .read, handle: try FileHandle(forReadingFrom: url))]
        }
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            files.append(ToolFile(parameter: "output", access: .write, handle: try FileHandle(forWritingTo: output), path: output.lastPathComponent))
        }
        let data = try await provider.call(tool, arguments: Data(arguments.utf8), files: files, context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A filled blob on a plain field: enough of a subject for the foreground mask to find.
    private func subjectImage() throws -> Data {
        let size = 512
        let space = CGColorSpaceCreateDeviceRGB()
        let canvas = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(colorSpace: space, components: [0.95, 0.95, 0.95, 1])!)
        canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
        canvas.setFillColor(CGColor(colorSpace: space, components: [0.15, 0.35, 0.8, 1])!)
        canvas.fillEllipse(in: CGRect(x: 140, y: 110, width: 230, height: 300))
        let image = try XCTUnwrap(canvas.makeImage())
        return try XCTUnwrap(CIContext().pngRepresentation(of: CIImage(cgImage: image), format: .RGBA8, colorSpace: space))
    }

    func testManifestAndToolListFollowTheProviderContract() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.id, "vision")
        XCTAssertEqual(provider.manifest.activation, .always)
        let listed = try await provider.tools(context: context)
        let tools = try ToolDescriptor.list(mcp: listed)
        XCTAssertEqual(tools.map(\.name), ["ocr", "classify", "barcodes", "cutout", "convert"])
        for tool in tools {
            let expected = ["cutout", "convert"].contains(tool.name)
                ? [ToolFileParameter(name: "image", access: .read), ToolFileParameter(name: "output", access: .write)]
                : [ToolFileParameter(name: "image", access: .read)]
            XCTAssertEqual(tool.fileParameters, expected, tool.name)
            XCTAssertTrue(tool.retryable, "\(tool.name) repeats without side effects, so a timed-out call may be repeated")
            XCTAssertFalse(tool.description.isEmpty)
        }
        for name in ["cutout", "convert"] {
            XCTAssertEqual(Set(try XCTUnwrap(tools.first { $0.name == name }).required), ["image", "output"], name)
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
        for (tool, image) in [("ocr", Data("not an image".utf8) as Data?), ("barcodes", nil), ("unknown", Data()), ("cutout", Data())] {
            let result = try await call(tool, image: image)
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
            XCTAssertFalse((((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "").isEmpty, tool)
        }
    }

    func testCutoutWritesTheSubjectOnTransparency() async throws {
        let output = root.appendingPathComponent("cutout.png")
        let result = try await call("cutout", image: try subjectImage(), output: output)
        if result["isError"] as? Bool == true, ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Vision could not run on this CI host: \(((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "")")
        }
        XCTAssertEqual(result["isError"] as? Bool, false, (((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""))
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["path"] as? String, "cutout.png")
        XCTAssertGreaterThanOrEqual(structured["subjects"] as? Int ?? 0, 1)
        let written = try XCTUnwrap(CIImage(contentsOf: output))
        XCTAssertGreaterThan(written.extent.width, 0)
        // A corner the subject never covers must be cut away.
        let context = CIContext()
        var pixel = [UInt8](repeating: 255, count: 4)
        context.render(written, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: written.extent.minX, y: written.extent.minY, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertEqual(pixel[3], 0, "the background corner should be transparent")
    }

    func testCutoutRefusesASubjectTheImageDoesNotHave() async throws {
        let output = root.appendingPathComponent("cutout.png")
        let result = try await call("cutout", image: try subjectImage(), arguments: "{\"subject\": 99}", output: output)
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    /// A 400×300 HEIC stored sideways: EXIF orientation 6 shows it 300 wide and 400 tall.
    private func sidewaysHEIC() throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.5, 0.3, 1])!)
        canvas.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testConvertTurnsAHEICIntoAnUprightJPEG() async throws {
        let output = root.appendingPathComponent("photo.jpg")
        let result = try await call("convert", image: try sidewaysHEIC(), arguments: "{\"max-size\": 200, \"quality\": 0.8}", output: output)
        XCTAssertEqual(result["isError"] as? Bool, false, (((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""))
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["path"] as? String, "photo.jpg")
        XCTAssertEqual(structured["width"] as? Int, 150)
        XCTAssertEqual(structured["height"] as? Int, 200)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 150)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 200)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1, "the pixels are turned, so no viewer turns them again")
    }

    func testConvertKeepsFullSizeAndRefusesAnUnknownFormat() async throws {
        let png = root.appendingPathComponent("photo.png")
        let full = try await call("convert", image: try sidewaysHEIC(), output: png)
        let structured = try XCTUnwrap(full["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["width"] as? Int, 300)
        XCTAssertEqual(structured["height"] as? Int, 400)
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))) as String?, UTType.png.identifier)
        let unknown = try await call("convert", image: try sidewaysHEIC(), output: root.appendingPathComponent("photo.txt"))
        XCTAssertEqual(unknown["isError"] as? Bool, true)
    }
}
