@testable import NoodleBrand
import SwiftUI
import XCTest

/// Chat effects look the same on every device that draws them.
@MainActor final class ChatEffectTests: XCTestCase {
    /// Names travel between apps as they are; one an app does not know is no effect there.
    func testEffectsAreKnownByName() {
        XCTAssertEqual(ChatEffect.allCases.map(\.rawValue), ["confetti", "fireworks"])
        XCTAssertNil(ChatEffect(rawValue: "future-kind"))
    }

    /// Partway through, each effect has drawn something, with or without motion.
    func testEachEffectDrawsWhilePlaying() throws {
        for effect in ChatEffect.allCases {
            for reduceMotion in [false, true] {
                // A still frame: a playing one never settles enough to be rendered off screen.
                let view = ChatEffectView(effect: effect, seed: UUID(), frozenAt: 1.2, reducesMotion: reduceMotion)
                    .frame(width: 400, height: 400)
                let renderer = ImageRenderer(content: view)
                let image = try XCTUnwrap(renderer.cgImage, "\(effect)")
                XCTAssertGreaterThan(drawnPixels(image), 50, "\(effect), reduce motion \(reduceMotion)")
            }
        }
    }

    private func drawnPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 0 }
    }
}
