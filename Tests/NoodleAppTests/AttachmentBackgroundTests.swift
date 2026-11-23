import AppKit
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// Use as Background on a picture or shader in a conversation: Use Here sets it in that conversation, and Choose
/// Conversations… in each one chosen, as each one's background editor would.
@MainActor final class AttachmentBackgroundTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    /// A file sent in Ada's conversation.
    private func sent(_ data: Data, named filename: String, _ f: StoreFixture) throws -> ConversationAttachment {
        let url = f.runtime.root.appendingPathComponent(filename)
        try data.write(to: url)
        f.store.importAttachment(from: url, into: f.directA.id)
        let file = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
        f.store.sendDraft(to: f.directA.id)
        return file
    }

    private func picture() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testUseHereSetsThePictureInItsOwnConversationOnly() async throws {
        let f = try fixture(), file = try sent(try picture(), named: "sunset.png", f)

        await f.store.useAttachmentAsBackground(file)

        XCTAssertNil(f.store.errorMessage)
        let saved = f.store.background(for: f.directA)
        XCTAssertEqual(saved.mediaKind ?? .image, .image)
        XCTAssertNotNil(saved.imageFilename)
        XCTAssertEqual(try f.repository.loadBackground(conversationID: f.directA.id), saved)
        XCTAssertTrue(f.store.background(for: f.directB).isDefault)
    }

    func testChosenConversationsEachGetThePictureAndItsOwnStaysAsItWas() async throws {
        let f = try fixture(), group = try f.group()
        let file = try sent(try picture(), named: "sunset.png", f)

        await f.store.useAttachmentAsBackground(file, in: [f.directB.id, group.id])

        XCTAssertNil(f.store.errorMessage)
        for conversation in [f.directB, group] {
            let saved = f.store.background(for: conversation)
            XCTAssertNotNil(saved.imageFilename, conversation.displayName)
            XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id), saved)
            let stored = try XCTUnwrap(f.repository.backgroundImageURL(saved, conversationID: conversation.id))
            XCTAssertNotNil(NSImage(contentsOf: stored), conversation.displayName)
        }
        XCTAssertNotEqual(f.store.background(for: f.directB).imageFilename, f.store.background(for: group).imageFilename)
        XCTAssertTrue(f.store.background(for: f.directA).isDefault)
        // The file itself stays in the conversation it was sent in.
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(file)), try picture())
    }

    func testChosenConversationsEachGetTheShader() async throws {
        let f = try fixture(), group = try f.group()
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            fragment float4 plasma(float4 p [[position]], constant float &time [[buffer(0)]]) {
                return float4(0.5 + 0.5 * sin(p.x * 0.01 + time), 0.3, 0.6, 1.0);
            }
            """
        let file = try sent(Data(source.utf8), named: "Plasma.metal", f)

        await f.store.useAttachmentAsBackground(file, in: [f.directB.id, group.id])

        XCTAssertNil(f.store.errorMessage)
        for conversation in [f.directB, group] {
            let saved = f.store.background(for: conversation)
            XCTAssertEqual(saved.mediaKind, .shader, conversation.displayName)
            let stored = try XCTUnwrap(f.repository.backgroundImageURL(saved, conversationID: conversation.id))
            XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), source)
        }
        XCTAssertTrue(f.store.background(for: f.directA).isDefault)
    }
}
