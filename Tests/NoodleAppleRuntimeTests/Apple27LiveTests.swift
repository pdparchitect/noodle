#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import CoreGraphics
import ImageIO
@testable import NoodleAppleRuntime

final class Apple27LiveTests: XCTestCase {
    @available(macOS 27, *)
    private func backend() async throws -> AppleModelBackend {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_APPLE_MODEL"] == "1" else {
            throw XCTSkip("Opt in with NOODLE_TEST_APPLE_MODEL=1.")
        }
        if let reason = AppleModel.systemUnavailableReason { throw XCTSkip(reason) }
        return try await AppleModelBackend.prepare(identifier: "default", workspace: FileManager.default.temporaryDirectory)
    }

    func testRequiredToolModeExitsAndProducesFinalAnswer() async throws {
        guard #available(macOS 27, *) else { return }
        let backend = try await backend()
        let calls = CallCount()
        let session = backend.session(tools: [RecordValue(calls: calls)],
            instructions: "Record the requested value with record_value, then report success. Call it once.", requireTool: true)
        let response = try await session.respond(to: "Record saffron.", options: .init(samplingMode: .greedy, maximumResponseTokens: 100))
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(response.content.isEmpty)
    }

    func testImagePromptRecognizesSyntheticRedSquare() async throws {
        guard #available(macOS 27, *) else { return }
        let backend = try await backend()
        guard backend.supportsImages else { throw XCTSkip("This device has no image capability.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apple-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.writeSquare(to: file)
        let session = backend.session(instructions: "Identify the color shown in the attached image. Answer in one word.")
        let response = try await session.respond(to: backend.prompt("What color is this square?", images: [file]),
            options: .init(samplingMode: .greedy, maximumResponseTokens: 32))
        XCTAssertTrue(response.content.lowercased().contains("red"), response.content)
    }

    static func writeSquare(to file: URL, color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

@available(macOS 27, *)
private actor CallCount { var count = 0; func record() { count += 1 } }

@available(macOS 27, *)
private struct RecordValue: Tool {
    let calls: CallCount
    let name = "record_value"
    let description = "Record a value once."
    @Generable struct Arguments { let value: String }
    func call(arguments: Arguments) async throws -> String {
        await calls.record()
        return "Recorded \(arguments.value). The task is complete."
    }
}
#endif
