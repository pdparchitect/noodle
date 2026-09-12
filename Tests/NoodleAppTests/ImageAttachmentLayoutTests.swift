import XCTest
import SwiftUI
import NoodleCore
@testable import Noodle

final class ImageAttachmentLayoutTests: XCTestCase {
    func testPortraitScreenshotsShareRowsAndReflowWhenNarrowed() {
        let sizes = Array(repeating: CGSize(width: 156, height: 240), count: 3)
        let wide = ImageRowPlan(sizes: sizes, availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(wide.size, CGSize(width: 484, height: 240))
        XCTAssertEqual(wide.frames.map(\.minX), [0, 164, 328])
        XCTAssertTrue(wide.frames.allSatisfy { $0.minY == 0 })

        let narrow = ImageRowPlan(sizes: sizes, availableWidth: 320, spacing: 8, trailing: false)
        XCTAssertEqual(narrow.size, CGSize(width: 320, height: 488))
        XCTAssertEqual(narrow.frames.map(\.origin), [.zero, CGPoint(x: 164, y: 0), CGPoint(x: 0, y: 248)])
    }

    func testMixedOrientationsStartNextRowBelowTallestImage() {
        let sizes = [CGSize(width: 300, height: 180), CGSize(width: 156, height: 240),
                     CGSize(width: 200, height: 200)]
        let plan = ImageRowPlan(sizes: sizes, availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(plan.size, CGSize(width: 464, height: 448))
        XCTAssertEqual(plan.frames[2].minY, 248)
        XCTAssertEqual(plan.frames.map(\.size), sizes, "Wrapping must not crop or stretch previews")
    }

    func testOutgoingRowsAlignToTheTrailingEdgeWithoutReversingImages() {
        let plan = ImageRowPlan(sizes: Array(repeating: CGSize(width: 156, height: 240), count: 3),
                                availableWidth: 320, spacing: 8, trailing: true)
        XCTAssertEqual(plan.frames.map(\.minX), [0, 164, 164])
        XCTAssertEqual(plan.frames.last?.maxX, plan.size.width)
    }

    func testUnspecifiedWidthAndZeroWidthProduceFiniteSizesWithoutEmptyRows() {
        let sizes = [CGSize(width: 156, height: 240), CGSize(width: 300, height: 180)]
        let ideal = ImageRowPlan(sizes: sizes, availableWidth: nil, spacing: 8, trailing: false)
        XCTAssertEqual(ideal.size, CGSize(width: 464, height: 240))
        let minimum = ImageRowPlan(sizes: sizes, availableWidth: 0, spacing: 8, trailing: false)
        XCTAssertEqual(minimum.size, CGSize(width: 300, height: 428))
        XCTAssertEqual(minimum.frames.first?.origin, .zero)
        let empty = ImageRowPlan(sizes: [], availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(empty.size, .zero)
        XCTAssertTrue(empty.frames.isEmpty)
    }

    @MainActor func testGroupingPreservesNonImageAttachmentsAndTheirOrder() {
        let image = attachment("image/png")
        let second = attachment("image/jpeg")
        let document = attachment("application/pdf")
        let third = attachment("image/png")
        let annotation = attachment("image/png", annotation: AttachmentAnnotation(
            source: image, comment: "Look here", region: .init(x: 0, y: 0, width: 1, height: 1)))
        let fourth = attachment("image/png")
        let items = [image, second, document, third, annotation, fourth]
        let runs = ImageAttachmentRun.group(items) { $0.isInlineImage(at: URL(fileURLWithPath: "/missing-fixture")) }
        XCTAssertEqual(runs.map { $0.attachments.map(\.id) },
                       [[image.id, second.id], [document.id], [third.id], [annotation.id], [fourth.id]])
        XCTAssertEqual(runs.map(\.isImage), [true, false, true, false, true])
        XCTAssertEqual(runs.flatMap(\.attachments), items)
    }

    /// Exercise SwiftUI's real proposal negotiation as well as the row arithmetic.
    @MainActor func testNativeLayoutUsesAvailableMessageWidth() throws {
        let images = [attachment("image/png"), attachment("image/png"), attachment("image/png")]
        for (width, expectedHeight): (CGFloat, CGFloat) in [(500, 200), (308, 408), (140, 576)] {
            let content = ImageAttachmentGroup(attachments: images, mode: .wrap, alignment: .leading) { _ in
                Color.blue.aspectRatio(0.75, contentMode: .fit)
                    .frame(idealWidth: 150, maxWidth: 150)
            }
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertLessThanOrEqual(CGFloat(image.width), width)
            XCTAssertEqual(CGFloat(image.height), expectedHeight, accuracy: 1)
        }
    }

    func testStackLeavesEachPictureExposedAndWrapsBeforeItRunsOutOfRoom() {
        let sizes = Array(repeating: CGSize(width: 150, height: 200), count: 3)
        let plan = ImageRowPlan(sizes: sizes, availableWidth: 500, spacing: 12,
                                trailing: false, overlapsImages: true)
        XCTAssertEqual(plan.size, CGSize(width: 276, height: 224))
        XCTAssertEqual(plan.frames.map(\.origin), [.zero, CGPoint(x: 63, y: 12), CGPoint(x: 126, y: 24)])
        XCTAssertEqual(plan.frames.map(\.size), sizes)
        for index in 0..<2 {
            let exposedPoint = CGPoint(x: plan.frames[index].minX + 30, y: plan.frames[index].midY)
            XCTAssertTrue(plan.frames[index].contains(exposedPoint))
            XCTAssertFalse(plan.frames.dropFirst(index + 1).contains { $0.contains(exposedPoint) },
                           "Each picture must retain a directly clickable exposed region")
        }
        let narrow = ImageRowPlan(sizes: sizes, availableWidth: 250, spacing: 12,
                                  trailing: true, overlapsImages: true)
        XCTAssertEqual(narrow.size, CGSize(width: 213, height: 424))
        XCTAssertEqual(narrow.frames.last?.origin, CGPoint(x: 63, y: 224))
    }

    func testStackBoundsIncludeWidePicturesBehindNarrowOnes() {
        let plan = ImageRowPlan(sizes: [CGSize(width: 220, height: 120), CGSize(width: 120, height: 220)],
                                availableWidth: 330, spacing: 12, trailing: true, overlapsImages: true)
        XCTAssertEqual(plan.size, CGSize(width: 220, height: 232))
        XCTAssertTrue(plan.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= plan.size.width })
    }

    @MainActor func testNativeStackRendersEveryPictureWithinItsCompactBounds() throws {
        let images = [attachment("image/png"), attachment("image/png"), attachment("image/png")]
        let colors: [Color] = [.red, .green, .blue]
        let stack = ImageAttachmentGroup(attachments: images, mode: .stack, alignment: .leading) { image in
            colors[images.firstIndex(of: image)!].aspectRatio(0.75, contentMode: .fit)
                .frame(idealWidth: 150, maxWidth: 150)
        }
        let renderer = ImageRenderer(content: stack)
        renderer.proposedSize = ProposedViewSize(width: 500, height: nil)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 276)
        XCTAssertEqual(image.height, 224)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for (x, y, component) in [(30, 100, 0), (93, 112, 1), (200, 124, 2)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            XCTAssertGreaterThan(components[component], 0.5, "Each exposed picture must actually be rendered")
            XCTAssertGreaterThan(components[component], components[(component + 1) % 3])
            XCTAssertGreaterThan(components[component], components[(component + 2) % 3])
        }
    }

    private func attachment(_ mediaType: String, annotation: AttachmentAnnotation? = nil) -> ConversationAttachment {
        ConversationAttachment(conversationID: UUID(), originalFilename: "fixture", storedFilename: "fixture",
                               mediaType: mediaType, byteCount: 1, annotation: annotation)
    }
}
