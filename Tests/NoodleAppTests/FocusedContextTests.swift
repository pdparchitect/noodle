import AppKit
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class FocusedContextTests: XCTestCase {
    private let chrome = FocusedContext(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", windowTitle: "Home / X",
        pageURL: "https://x.com/compose/post", fieldLabel: "Post text", fieldRole: "text entry area",
        text: "Shipping it today", selection: "today")

    /// The note says where the context came from, then the selection and the field's text, each fenced so
    /// the bot reads them as quoted text.
    func testTheNoteNamesTheAppPageAndFieldAndQuotesItsText() {
        let note = chrome.note
        XCTAssertTrue(note.hasPrefix("# Context from Google Chrome\n"), note)
        XCTAssertTrue(note.contains("- Window: Home / X\n"), note)
        XCTAssertTrue(note.contains("- Page: https://x.com/compose/post\n"), note)
        XCTAssertTrue(note.contains("- Field: Post text (text entry area)\n"), note)
        XCTAssertTrue(note.contains("## Selected text\n\n```\ntoday\n```"), note)
        XCTAssertTrue(note.contains("## Field text\n\n```\nShipping it today\n```"), note)
        XCTAssertEqual(chrome.title, "Home / X")
    }

    /// A long field keeps its end, where people type; a fence in the text cannot close the quote.
    func testLongTextKeepsItsEndAndFencesCannotBreakOut() {
        var context = chrome
        context.selection = nil
        context.text = String(repeating: "a", count: 30_000) + "END"
        let note = context.note
        XCTAssertTrue(note.contains("aEND\n"), "The end is kept")
        XCTAssertLessThan(note.count, 21_000)
        XCTAssertTrue(note.contains("10,003 earlier characters left out"), note)
        XCTAssertFalse(note.contains("## Selected text"))

        context.text = "Before\n```\nAfter"
        XCTAssertTrue(context.note.contains("````\nBefore\n```\nAfter\n````"), context.note)
    }

    /// An app with no readable field still says which app and window it was.
    func testAnAppWithoutAFieldStillNamesItself() {
        let context = FocusedContext(appName: "Preview", bundleIdentifier: "com.apple.Preview", windowTitle: nil,
            pageURL: nil, fieldLabel: nil, fieldRole: nil, text: nil, selection: nil)
        XCTAssertEqual(context.note, "# Context from Preview\n")
        XCTAssertEqual(context.title, "Preview")
    }

    /// Picking a conversation with context waits in its message field, ready to send, and sends nothing.
    func testContextIsStagedInThePickedConversationWithoutSending() throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        try f.store.stageContext(chrome, screenshot: image, into: f.directA.id)

        let staged = f.store.pendingAttachments(for: f.directA.id)
        XCTAssertEqual(staged.map(\.mediaType), ["image/png", "text/markdown"])
        XCTAssertEqual(staged.map(\.originalFilename), ["Capture — Home - X.png", "Context — Home - X.md"])
        let note = try String(contentsOf: f.store.attachmentFileURL(staged[1]), encoding: .utf8)
        XCTAssertEqual(note, chrome.note)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty)
        XCTAssertTrue(try f.repository.loadMessages(conversationID: f.directA.id).isEmpty)

        // Without Screen Recording there is no picture, only the note.
        try f.store.stageContext(chrome, screenshot: nil, into: f.directB.id)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id).map(\.mediaType), ["text/markdown"])
    }
}
