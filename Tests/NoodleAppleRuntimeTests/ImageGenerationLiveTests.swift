import ImageIO
import XCTest
@testable import NoodleAppleRuntime
@testable import NoodleCore

/// Makes real images with a downloaded SDXL model, from a prompt and then from that picture, so a
/// change to the copied Stable Diffusion code or to MLX is checked end to end.
final class ImageGenerationLiveTests: XCTestCase {
    func testTextAndPictureMakeImagesOfTheRequestedSize() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_IMAGE_MODEL"] else {
            throw XCTSkip("Set NOODLE_TEST_IMAGE_MODEL to a downloaded image model's weights folder.")
        }
        let weights = URL(fileURLWithPath: path)
        let request = ImageGenerationRequest(weights: weights, prompt: "a red apple on a wooden table", negativePrompt: "",
                                             steps: 2, guidance: 0, width: 256, height: 256, seed: 7)
        let drawn = try ImageGeneration.png(request)
        try assertImage(drawn, width: 256, height: 256)

        var edit = request
        edit.prompt = "a green apple on a wooden table"
        edit.image = drawn
        edit.strength = 0.5
        try assertImage(try ImageGeneration.png(edit), width: 256, height: 256)
    }

    private func assertImage(_ data: Data, width: Int, height: Int) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }
}
