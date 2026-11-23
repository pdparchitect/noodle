import XCTest
@testable import NoodleWallpaper

/// Still pictures keep a dim so bubbles read over them. A video or shader plays undimmed, behind
/// dark glass bubbles, so its colours stay as made.
final class BackgroundDimTests: XCTestCase {
    func testOnlyStillPicturesAreDimmed() {
        let still = ConversationBackground(imageFilename: "photo.jpg", mediaKind: .image)
        let dynamic = ConversationBackground(imageFilename: "desktop.heic", mediaKind: .dynamicImage)
        let older = ConversationBackground(imageFilename: "photo.jpg")
        let video = ConversationBackground(imageFilename: "clip.mp4", mediaKind: .video)
        let shader = ConversationBackground(imageFilename: "aurora.metal", mediaKind: .shader)
        let preset = ConversationBackground(preset: .midnight)

        for background in [still, dynamic, older] {
            XCTAssertFalse(background.isMoving)
            XCTAssertEqual(ConversationBackgroundView.dim(for: background), 0.25, background.imageFilename ?? "")
        }
        for background in [video, shader] {
            XCTAssertTrue(background.isMoving)
            XCTAssertEqual(ConversationBackgroundView.dim(for: background), 0, background.imageFilename ?? "")
        }
        for background in [preset, ConversationBackground()] {
            XCTAssertFalse(background.isMoving)
            XCTAssertEqual(ConversationBackgroundView.dim(for: background), 0)
        }
    }
}
