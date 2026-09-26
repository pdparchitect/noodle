import BrowserBridge
@testable import NoodleBrowser
import XCTest

/// Someone watching a browser live sees its tab strip above the page, drawn where nobody clicks
/// it directly; their clicks on it select, close and open tabs.
@MainActor final class BrowserLiveViewTests: XCTestCase {
    func testTheTabStripDrawsOffscreenAndKnowsWhatWasClicked() async throws {
        let first = BrowserTabInfo(title: "DAWO.community"), second = BrowserTabInfo(title: "Service Bus")
        let strip = BrowserTabStripPicture()
        var picture: CGImage?
        for _ in 0..<50 {
            picture = strip.render(tabs: [first, second], selected: second.id, width: 800, scale: 2)
            if strip.target(at: CGPoint(x: 790, y: BrowserTabStrip.height / 2)) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try XCTUnwrap(picture)
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, Int(BrowserTabStrip.height * 2))
        XCTAssertGreaterThan(Set(samples(image)).count, 1, "the strip drew nothing")

        let middle = BrowserTabStrip.height / 2
        XCTAssertEqual(strip.target(at: CGPoint(x: 790, y: middle)), .newTab)
        let tabs = (0..<700).compactMap { strip.target(at: CGPoint(x: Double($0), y: middle)) }
        XCTAssertTrue(tabs.contains(.tab(first.id)))
        XCTAssertTrue(tabs.contains(.tab(second.id)))
        XCTAssertTrue(tabs.contains(.close(second.id)))
        // The close button sits over the end of its tab and wins there.
        let closing = try XCTUnwrap((0..<700).first { strip.target(at: CGPoint(x: Double($0), y: middle)) == .close(first.id) })
        XCTAssertEqual(strip.target(at: CGPoint(x: Double(closing) + 2, y: middle)), .close(first.id))
        XCTAssertNil(strip.target(at: CGPoint(x: 10, y: BrowserTabStrip.height + 5)), "a point below the strip hit it")
    }

    private func samples(_ image: CGImage) -> [UInt32] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt32.self, capacity: image.width * image.height)
        return stride(from: 0, to: image.width * image.height, by: 97).map { pixels[$0] }
    }
}
