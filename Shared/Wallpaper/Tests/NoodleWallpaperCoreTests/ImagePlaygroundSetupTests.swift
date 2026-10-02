import AppKit
import ImagePlayground
import SwiftUI
import XCTest
@testable import NoodleWallpaperCore

@MainActor
final class ImagePlaygroundSetupTests: XCTestCase {
    @available(macOS 27, *)
    private struct Probe: View {
        @Environment(\.imagePlaygroundOptions) private var options
        @Environment(\.imagePlaygroundSelectedGenerationStyle) private var style
        let seen: (ImagePlaygroundOptions, ImagePlaygroundStyle) -> Void
        var body: some View {
            seen(options, style)
            return Color.clear
        }
    }

    @available(macOS 27, *)
    private func setup(shapedLike size: CGSize?) -> (ImagePlaygroundOptions, ImagePlaygroundStyle)? {
        var result: (ImagePlaygroundOptions, ImagePlaygroundStyle)?
        let renderer = ImageRenderer(content: Probe { result = ($0, $1) }.noodleImagePlayground(shapedLike: size).frame(width: 10, height: 10))
        _ = renderer.nsImage
        return result
    }

    func testStartsOnIllustrationWithoutPeopleFromPhotos() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Image sizes need macOS 27.") }
        let (options, style) = try XCTUnwrap(setup(shapedLike: nil))
        XCTAssertEqual(style, .illustration)
        XCTAssertEqual(options.personalization, .disabled)
        #if canImport(ImagePlayground, _version: 198)
        XCTAssertEqual(options.sizeSpecification, ImagePlaygroundOptions().sizeSpecification)
        #endif
    }

    #if canImport(ImagePlayground, _version: 198)
    func testShapesTheImageLikeTheScreen() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Image sizes need macOS 27.") }
        let (options, _) = try XCTUnwrap(setup(shapedLike: CGSize(width: 1600, height: 900)))
        XCTAssertEqual(options.sizeSpecification, .closest(to: CGSize(width: 1600, height: 900)))
        XCTAssertEqual(options.personalization, .disabled)
    }
    #endif
}
