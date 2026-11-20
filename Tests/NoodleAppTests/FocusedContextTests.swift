import AppKit
import XCTest
import NoodleContextFieldsTools
import NoodleCore
@testable import Noodle

@MainActor final class FocusedContextTests: XCTestCase {
    private let chrome = FocusedContext(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", windowTitle: "Home / X",
        pageURL: "https://x.com/compose/post", fieldLabel: "Post text", fieldRole: "text entry area",
        text: "Shipping it today", selection: "today",
        fieldFrame: CGRect(x: 100, y: 200, width: 300, height: 50), windowFrame: CGRect(x: 50, y: 100, width: 1000, height: 500))

    /// The comment says where the context came from; the quote is the selection, or else the field's text.
    func testTheCommentSaysWhereAndTheQuoteIsTheText() {
        XCTAssertEqual(chrome.comment, "Context from Google Chrome: Home / X\nhttps://x.com/compose/post\nField: Post text (text entry area), selected text quoted")
        XCTAssertEqual(chrome.quote, "today")
        var whole = chrome
        whole.selection = ""
        XCTAssertEqual(whole.quote, "Shipping it today")
        XCTAssertEqual(whole.comment, "Context from Google Chrome: Home / X\nhttps://x.com/compose/post\nField: Post text (text entry area)")
        XCTAssertEqual(chrome.title, "Home / X")
    }

    /// The field is marked where it sits in the window, from the bottom-left as annotations count.
    func testTheRegionIsTheFieldWithinTheWindow() throws {
        let region = try XCTUnwrap(chrome.region)
        XCTAssertEqual(region.x, 0.05, accuracy: 0.0001)
        XCTAssertEqual(region.y, 0.7, accuracy: 0.0001)
        XCTAssertEqual(region.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(region.height, 0.1, accuracy: 0.0001)
        XCTAssertTrue(region.isValid)
        var outside = chrome
        outside.fieldFrame = CGRect(x: 2000, y: 2000, width: 10, height: 10)
        XCTAssertNil(outside.region)
    }

    /// A long field keeps its end, where people type, and the comment says how much was left out.
    func testLongTextKeepsItsEnd() throws {
        var context = chrome
        context.selection = nil
        context.text = String(repeating: "a", count: 30_000) + "END"
        let quote = try XCTUnwrap(context.quote)
        XCTAssertEqual(quote.count, FocusedContext.textLimit)
        XCTAssertTrue(quote.hasSuffix("aEND"))
        XCTAssertTrue(context.comment.hasSuffix("\nThe first 10,003 characters of the field are left out."), context.comment)
    }

    /// An app with no readable field still says which app it was.
    func testAnAppWithoutAFieldStillNamesItself() {
        let context = FocusedContext(appName: "Preview", bundleIdentifier: "com.apple.Preview")
        XCTAssertEqual(context.comment, "Context from Preview")
        XCTAssertNil(context.quote)
        XCTAssertNil(context.region)
        XCTAssertEqual(context.title, "Preview")
    }

    /// Picking a conversation with context leaves one annotation in its message field: the window with the
    /// field outlined, quoting its text. Nothing is sent.
    func testContextWaitsAsOneAnnotationWithoutSending() throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        try f.store.stageContext(chrome, screenshot: image, into: f.directA.id)

        let staged = f.store.pendingAttachments(for: f.directA.id)
        XCTAssertEqual(staged.count, 1)
        let note = try XCTUnwrap(staged.first?.annotation)
        XCTAssertEqual(staged.first?.mediaType, "image/png")
        XCTAssertEqual(note.sourceFilename, "Capture — Home - X.png")
        XCTAssertEqual(note.quote, "today")
        XCTAssertEqual(note.comment, chrome.comment)
        XCTAssertEqual(note.region, chrome.region)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty)
        XCTAssertTrue(try f.repository.loadMessages(conversationID: f.directA.id).isEmpty)

        // Without a field the whole window is marked.
        try f.store.stageContext(FocusedContext(appName: "Preview", bundleIdentifier: nil), screenshot: image, into: f.directB.id)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id).first?.annotation?.region,
                       AttachmentAnnotation.Region(x: 0, y: 0, width: 1, height: 1))
    }

    /// Without Screen Recording there is no picture, so the field's text goes as a text annotation.
    func testWithoutAPictureTheTextGoesAsATextAnnotation() throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        try f.store.stageContext(chrome, screenshot: nil, into: f.directA.id)
        let staged = f.store.pendingAttachments(for: f.directA.id)
        XCTAssertEqual(staged.map(\.mediaType), ["text/plain"])
        let note = try XCTUnwrap(staged.first?.annotation)
        XCTAssertEqual(note.sourceFilename, "Context — Home - X.txt")
        XCTAssertEqual(note.quote, "today")
        XCTAssertNil(note.region)
        XCTAssertEqual(note.comment, chrome.comment)
    }

    /// Fields nobody touches, for tests that only follow the grants.
    private final class StillFields: ContextFieldSurface, @unchecked Sendable {
        func value(of field: String) async -> String? { "Shipping it today" }
        func setText(_ text: String, of field: String) async {}
        func press(_ field: String) async {}
        func choose(_ option: String, in field: String) async {}
    }

    /// Captured fields wait with the context; once it is sent, each bot it went to holds its own token.
    func testSentContextGivesEachBotItsOwnWayToFillTheFields() throws {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let group = try f.group()
        let capture = ContextFieldCapture(app: "Google Chrome", window: "Home / X", page: "https://x.com/compose/post",
            fields: [ContextField(id: "f1", label: "Post text", kind: .text, value: "Shipping it today")], surface: StillFields())
        try f.store.stageContext(chrome, screenshot: nil, fields: capture, into: group.id)
        let note = try XCTUnwrap(f.store.pendingAttachments(for: group.id).first?.annotation)
        XCTAssertEqual(note.comment, chrome.comment + "\nUntil 15 minutes after this is sent, its fields can be filled with the context-fields tool.")
        XCTAssertTrue(f.store.contextFields.grants(for: f.a.id).isEmpty, "nothing until it is sent")

        f.store.sendDraft(to: group.id)
        let ada = f.store.contextFields.grants(for: f.a.id), grace = f.store.contextFields.grants(for: f.b.id)
        XCTAssertEqual(ada.count, 1)
        XCTAssertEqual(grace.count, 1)
        XCTAssertNotEqual(ada.first?.token, grace.first?.token)
        XCTAssertEqual(ada.first?.capture.fields.map(\.label), ["Post text"])

        // Context without fields says nothing about filling them.
        try f.store.stageContext(chrome, screenshot: nil, into: f.directB.id)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id).first?.annotation?.comment, chrome.comment)
    }
}
