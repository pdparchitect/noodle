import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class AttachmentDropTests: XCTestCase {
    func testFilesDroppedOnMountedComposerAttachToDisplayedConversationWithoutChangingDraft() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, conversation = fixture.directB
        store.selectedConversationID = fixture.directA.id
        store.setDraft("Keep this draft", for: conversation.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationWindowView(conversationID: conversation.id).environment(store))
        defer { window.close(); window.contentView = nil }
        func editor(in view: NSView?) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view?.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<100 where editor(in: window.contentView) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let input = try XCTUnwrap(editor(in: window.contentView))
        let filenames = ["README.md", "Notes.txt", "Code.swift", "Data.custom", "LICENSE"]
        let urls = try filenames.map { name in
            let url = fixture.repository.rootURL.appendingPathComponent(name)
            try Data("Contents of \(name)".utf8).write(to: url)
            return url
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))
        XCTAssertTrue(input.registeredDraggedTypes.contains(.fileURL))
        let type = try XCTUnwrap(input.preferredPasteboardType(from: pasteboard.types ?? [], restrictedToTypesFrom: input.acceptableDragTypes))
        XCTAssertEqual(type, .fileURL)
        let drag = FileDragInfo(pasteboard: pasteboard, window: window,
            location: input.convert(NSPoint(x: 5, y: 5), to: nil))
        XCTAssertEqual(input.draggingEntered(drag), .copy)
        XCTAssertEqual(input.draggingUpdated(drag), .copy)
        XCTAssertTrue(input.prepareForDragOperation(drag))
        XCTAssertTrue(input.performDragOperation(drag))
        input.concludeDragOperation(drag)
        XCTAssertEqual(input.string, "Keep this draft")
        XCTAssertEqual(store.draft(for: conversation.id), "Keep this draft")
        XCTAssertTrue(store.pendingAttachments(for: fixture.directA.id).isEmpty)
        let attachments = store.pendingAttachments(for: conversation.id)
        XCTAssertEqual(attachments.map(\.originalFilename), filenames)
        for attachment in attachments {
            XCTAssertEqual(try Data(contentsOf: store.attachmentFileURL(attachment)),
                Data("Contents of \(attachment.originalFilename)".utf8))
        }
        XCTAssertNil(store.errorMessage)
    }

    func testPlainTextStillInsertsIntoComposer() {
        let input = ComposerScrollView().editor
        var attached = false
        input.dropFiles = { _ in attached = true }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("Some ordinary text", forType: .string))
        XCTAssertTrue(input.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(input.string, "Some ordinary text")
        XCTAssertFalse(attached)
    }

    func testDroppedDocumentDataImportsIntoOriginalDraftAndCanBeSent() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, conversation = fixture.directB
        store.selectedConversationID = conversation.id
        let bytes = Data("# Markdown attachment\n".utf8)
        let provider = NSItemProvider()
        provider.suggestedName = "README.md"
        provider.registerDataRepresentation(for: UTType(filenameExtension: "md")!, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        store.importAttachments(from: [provider])
        store.selectedConversationID = fixture.directA.id
        for _ in 0..<100 where store.pendingAttachments(for: conversation.id).isEmpty && store.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attachment = try XCTUnwrap(store.pendingAttachments(for: conversation.id).first, store.errorMessage ?? "Missing attachment")
        XCTAssertEqual(attachment.originalFilename, "README.md")
        XCTAssertEqual(try Data(contentsOf: store.attachmentFileURL(attachment)), bytes)
        XCTAssertTrue(store.pendingAttachments(for: fixture.directA.id).isEmpty)
        store.sendDraft(to: conversation.id)
        XCTAssertEqual(store.messages(for: conversation).last?.attachments, [attachment.id])
        XCTAssertNil(store.errorMessage)
    }
}

@MainActor private final class FileDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
