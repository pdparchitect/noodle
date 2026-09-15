import XCTest
import SwiftUI
import NoodleCore
import AppletBridge
@testable import Noodle

final class AttachmentLayoutTests: XCTestCase {
    func testPortraitScreenshotsShareRowsAndReflowWhenNarrowed() {
        let sizes = Array(repeating: CGSize(width: 156, height: 240), count: 3)
        let wide = AttachmentRowPlan(sizes: sizes, availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(wide.size, CGSize(width: 484, height: 240))
        XCTAssertEqual(wide.frames.map(\.minX), [0, 164, 328])
        XCTAssertTrue(wide.frames.allSatisfy { $0.minY == 0 })

        let narrow = AttachmentRowPlan(sizes: sizes, availableWidth: 320, spacing: 8, trailing: false)
        XCTAssertEqual(narrow.size, CGSize(width: 320, height: 488))
        XCTAssertEqual(narrow.frames.map(\.origin), [.zero, CGPoint(x: 164, y: 0), CGPoint(x: 0, y: 248)])
    }

    func testMixedOrientationsStartNextRowBelowTallestImage() {
        let sizes = [CGSize(width: 300, height: 180), CGSize(width: 156, height: 240),
                     CGSize(width: 200, height: 200)]
        let plan = AttachmentRowPlan(sizes: sizes, availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(plan.size, CGSize(width: 464, height: 448))
        XCTAssertEqual(plan.frames[2].minY, 248)
        XCTAssertEqual(plan.frames.map(\.size), sizes, "Wrapping must not crop or stretch previews")
    }

    func testOutgoingRowsAlignToTheTrailingEdgeWithoutReversingImages() {
        let plan = AttachmentRowPlan(sizes: Array(repeating: CGSize(width: 156, height: 240), count: 3),
                                availableWidth: 320, spacing: 8, trailing: true)
        XCTAssertEqual(plan.frames.map(\.minX), [0, 164, 164])
        XCTAssertEqual(plan.frames.last?.maxX, plan.size.width)
    }

    func testUnspecifiedWidthAndZeroWidthProduceFiniteSizesWithoutEmptyRows() {
        let sizes = [CGSize(width: 156, height: 240), CGSize(width: 300, height: 180)]
        let ideal = AttachmentRowPlan(sizes: sizes, availableWidth: nil, spacing: 8, trailing: false)
        XCTAssertEqual(ideal.size, CGSize(width: 464, height: 240))
        let minimum = AttachmentRowPlan(sizes: sizes, availableWidth: 0, spacing: 8, trailing: false)
        XCTAssertEqual(minimum.size, CGSize(width: 300, height: 428))
        XCTAssertEqual(minimum.frames.first?.origin, .zero)
        let empty = AttachmentRowPlan(sizes: [], availableWidth: 500, spacing: 8, trailing: false)
        XCTAssertEqual(empty.size, .zero)
        XCTAssertTrue(empty.frames.isEmpty)
    }

    /// Exercise SwiftUI's real proposal negotiation as well as the row arithmetic.
    @MainActor func testNativeLayoutUsesAvailableMessageWidth() throws {
        let images = [attachment("image/png"), attachment("image/png"), attachment("image/png")]
        for (width, expectedHeight): (CGFloat, CGFloat) in [(500, 200), (308, 408), (140, 576)] {
            let content = AttachmentGroup(attachments: images, mode: .wrap, alignment: .leading) { _ in
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
        let plan = AttachmentRowPlan(sizes: sizes, availableWidth: 500, spacing: 12,
                                trailing: false, overlapsAttachments: true)
        XCTAssertEqual(plan.size, CGSize(width: 276, height: 224))
        XCTAssertEqual(plan.frames.map(\.origin), [.zero, CGPoint(x: 63, y: 12), CGPoint(x: 126, y: 24)])
        XCTAssertEqual(plan.frames.map(\.size), sizes)
        for index in 0..<2 {
            let exposedPoint = CGPoint(x: plan.frames[index].minX + 30, y: plan.frames[index].midY)
            XCTAssertTrue(plan.frames[index].contains(exposedPoint))
            XCTAssertFalse(plan.frames.dropFirst(index + 1).contains { $0.contains(exposedPoint) },
                           "Each picture must retain a directly clickable exposed region")
        }
        let narrow = AttachmentRowPlan(sizes: sizes, availableWidth: 250, spacing: 12,
                                  trailing: true, overlapsAttachments: true)
        XCTAssertEqual(narrow.size, CGSize(width: 213, height: 424))
        XCTAssertEqual(narrow.frames.last?.origin, CGPoint(x: 63, y: 224))
    }

    func testStackBoundsIncludeWidePicturesBehindNarrowOnes() {
        let plan = AttachmentRowPlan(sizes: [CGSize(width: 220, height: 120), CGSize(width: 120, height: 220)],
                                availableWidth: 330, spacing: 12, trailing: true, overlapsAttachments: true)
        XCTAssertEqual(plan.size, CGSize(width: 220, height: 232))
        XCTAssertTrue(plan.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= plan.size.width })
    }

    @MainActor func testNativeStackRendersEveryPictureWithinItsCompactBounds() throws {
        let images = [attachment("image/png"), attachment("image/png"), attachment("image/png")]
        let colors: [Color] = [.red, .green, .blue]
        let stack = AttachmentGroup(attachments: images, mode: .stack, alignment: .leading) { image in
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

    @MainActor func testRealMixedAttachmentsFitNarrowLayoutsAndKeepTheirOrder() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let source = attachment("image/png")
        let region = attachment("image/png", annotation: AttachmentAnnotation(source: source,
            comment: "Move the header below the window controls.", region: .init(x: 0, y: 0, width: 1, height: 1)))
        let quote = attachment("text/plain", annotation: AttachmentAnnotation(source: source,
            quote: "Selected text", comment: "Clarify this passage."))
        let voice = ConversationAttachment(conversationID: UUID(), originalFilename: "Voice.caf", storedFilename: "Voice.caf",
            mediaType: "audio/x-caf", byteCount: 1,
            voice: VoiceMessage(transcript: nil, duration: 12, waveform: [0.2, 0.8], localeIdentifier: nil))
        let noodlet = ConversationAttachment(conversationID: UUID(), originalFilename: "Noodlet", storedFilename: "Noodlet",
            mediaType: "text/uri-list", byteCount: 1, url: NoodletLink.url(for: UUID()))
        let items = [source, region, attachment("application/pdf"), quote, voice, noodlet]
        let file = URL(fileURLWithPath: "/missing-layout-fixture")
        for mode in ChatAttachmentLayout.allCases {
            for width: CGFloat in [180, 500, 900] {
                let previews = items.map { item in
                    AttachmentInlinePreview(attachment: item, fileURL: file, shouldLoad: false,
                        isSelected: false, select: {}, preview: {}).environment(f.store)
                }
                let sizes = try previews.map { preview in
                    let renderer = ImageRenderer(content: preview)
                    renderer.proposedSize = ProposedViewSize(width: mode == .stack ? min(220, width) : width, height: nil)
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertLessThanOrEqual(CGFloat(image.width), width, "Every attachment type must fit a narrow chat")
                    return CGSize(width: image.width, height: image.height)
                }
                let group = AttachmentGroup(attachments: items, mode: mode, alignment: .trailing) { item in
                    previews[items.firstIndex(of: item)!]
                }
                let renderer = ImageRenderer(content: group)
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertLessThanOrEqual(CGFloat(image.width), width)
                if mode == .vertical {
                    XCTAssertEqual(CGFloat(image.height), sizes.map(\.height).reduce(0, +) + 15, accuracy: 6)
                } else {
                    let plan = AttachmentRowPlan(sizes: sizes, availableWidth: width,
                        spacing: mode == .stack ? 12 : 8, trailing: true, overlapsAttachments: mode == .stack)
                    XCTAssertEqual(CGFloat(image.height), plan.size.height, accuracy: 6)
                    for index in 1..<plan.frames.count {
                        let previous = plan.frames[index - 1], current = plan.frames[index]
                        XCTAssertTrue(current.minY > previous.minY || current.minX > previous.minX,
                            "Mixed attachments must retain their message order")
                    }
                }
            }
        }
    }

    @MainActor func testAnnotationHeavyMessageUsesTheSavedLayoutForBothAuthors() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let snapshot = NSImage(size: CGSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill()
            NSColor.systemOrange.setFill(); rect.insetBy(dx: 90, dy: 60).fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try f.repository.importAttachment(data: data, originalFilename: "Screenshot.png",
            into: f.directA.id, mediaType: "image/png")
        let items = try (0..<6).map { index in
            let note = AttachmentAnnotation(source: source, comment: "Review region \(index)",
                region: .init(x: 0, y: 0, width: 1, height: 1))
            return try f.repository.importAttachment(data: data, originalFilename: "Annotation \(index).png",
                into: f.directA.id, mediaType: "image/png", annotation: note)
        }
        for author in [MessageAuthor.user, .agent(f.a.id)] {
            let message = ChatMessage(conversationID: f.directA.id, author: author, body: "Review these annotations",
                delivery: .delivered, attachmentIDs: items.map(\.id))
            try f.repository.append(message)
            f.store.refreshTranscripts()
            var heights: [ChatAttachmentLayout: Int] = [:]
            for mode in ChatAttachmentLayout.allCases {
                f.runtime.defaults.set(mode.rawValue, forKey: ChatAttachmentLayout.defaultsKey)
                let bubble = MessageBubble(message: message, hasConversationBackground: false,
                    selectedAttachmentID: .constant(nil), previewAttachment: { _ in }, showAgentProfile: nil)
                    .environment(f.store).defaultAppStorage(f.runtime.defaults)
                let renderer = ImageRenderer(content: bubble)
                renderer.proposedSize = ProposedViewSize(width: 1050, height: nil)
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertLessThanOrEqual(image.width, 1050)
                heights[mode] = image.height
            }
            let vertical = try XCTUnwrap(heights[.vertical])
            XCTAssertLessThan(try XCTUnwrap(heights[.wrap]), vertical / 2,
                "Six annotation cards should share rows instead of filling one tall column")
            XCTAssertLessThan(try XCTUnwrap(heights[.stack]), try XCTUnwrap(heights[.wrap]))
        }
    }

    private func attachment(_ mediaType: String, annotation: AttachmentAnnotation? = nil) -> ConversationAttachment {
        ConversationAttachment(conversationID: UUID(), originalFilename: "fixture", storedFilename: "fixture",
                               mediaType: mediaType, byteCount: 1, annotation: annotation)
    }
}
