import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class SavedAnnotationInteractionTests: HiddenViewTests {
    private func note(_ f: StoreFixture, quote: Bool = true, region: Bool = false, version: Int = 2) throws -> ConversationAttachment {
        let source = try f.repository.importAttachment(data: Data("Original source".utf8), originalFilename: "Document.txt",
            into: f.directA.id, mediaType: "text/plain")
        let note = AttachmentAnnotation(source: source, quote: quote && !region ? "Selected passage" : nil,
            comment: "First comment", region: region ? .init(x: 0.1, y: 0.2, width: 0.4, height: 0.5) : nil, version: version)
        let snapshot = region ? NSImage(size: .init(width: 60, height: 40), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        } : nil
        let data: Data
        if version == 1 {
            // Legacy notes are read from existing PDFs; the current creation
            // path intentionally emits only version 2 annotations.
            let bytes = NSMutableData()
            var rect = CGRect(x: 0, y: 0, width: 60, height: 40)
            let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &rect, nil))
            for color in [CGColor(gray: 1, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
                context.beginPDFPage(nil); context.setFillColor(color); context.fill(rect); context.endPDFPage()
            }
            context.closePDF(); data = bytes as Data
        } else { data = try AnnotationContent.data(for: note, snapshot: snapshot) }
        try f.store.saveAnnotation(note, content: data, source: source)
        return try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
    }
    private func preview(_ f: StoreFixture, _ note: ConversationAttachment, editable: Bool = true) throws -> AnnotationPreviewController {
        let owner = try XCTUnwrap(host(Text("Source fixture")).window)
        let controller = AnnotationPreviewController(present: { XCTAssertFalse($0.isVisible) })
        addTeardownBlock { @MainActor in controller.close() }
        controller.show(note, url: f.store.attachmentFileURL(note), relativeTo: owner,
            edit: editable ? { try f.store.reviseAnnotationComment($0, comment: $1) } : nil,
            canEdit: { f.store.canEditAnnotation($0) })
        return controller
    }
    private func content(_ controller: AnnotationPreviewController) throws -> NSView {
        try XCTUnwrap(controller.window?.contentView)
    }
    private func editor(in view: NSView) async throws -> NSTextView {
        var editor: NSTextView?
        try await wait { editor = self.elements(view).compactMap { $0 as? NSTextView }.first { $0.isEditable }; return editor != nil }
        return try XCTUnwrap(editor)
    }
    private func editComment(_ text: String, in view: NSView) async throws {
        let editor = try await editor(in: view)
        editor.string = text; editor.didChangeText()
    }

    func testRepeatedNativeEditsSaveTheCurrentAttachmentAndPreserveItsSource() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original)
        let view = try content(controller)
        _ = try await control("Selected passage", in: view)
        for comment in ["  Second comment  ", "Third comment"] {
            press(try await control("Edit Comment", in: view))
            try await editComment(comment, in: view)
            press(try await control("Save", in: view))
            _ = try await control(comment.trimmingCharacters(in: .whitespacesAndNewlines), in: view)
        }
        let saved = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).first { $0.id == original.id })
        XCTAssertEqual(saved.annotation?.comment, "Third comment")
        XCTAssertEqual(saved.annotation?.quote, "Selected passage")
        XCTAssertEqual(saved.annotation?.sourceAttachmentID, original.annotation?.sourceAttachmentID)
        XCTAssertEqual(try String(contentsOf: f.store.attachmentFileURL(saved), encoding: .utf8), saved.annotation?.textRepresentation)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    func testCancellingDiscardsTheEditedTextAndReopeningRestoresTheSavedComment() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original)
        let view = try content(controller), file = f.store.attachmentFileURL(original), before = try Data(contentsOf: file)
        press(try await control("Edit Comment", in: view))
        try await editComment("Discard this", in: view)
        press(try await control("Cancel", in: view))
        _ = try await control("First comment", in: view)
        XCTAssertEqual(try Data(contentsOf: file), before)
        press(try await control("Edit Comment", in: view))
        let field = try await editor(in: view)
        XCTAssertEqual(field.string, "First comment")
    }

    func testBlankCommentCannotSaveAndWholeAttachmentCanBeEdited() async throws {
        let f = try fixture(), original = try note(f, quote: false), controller = try preview(f, original)
        let view = try content(controller)
        _ = try await control("Whole attachment", in: view)
        press(try await control("Edit Comment", in: view))
        try await editComment("  \n ", in: view)
        let save = try await control("Save", in: view)
        try await wait { !self.enabled(save) }
        try await editComment("Whole document feedback", in: view)
        try await wait { self.enabled(save) }; press(save)
        _ = try await control("Whole document feedback", in: view)
        XCTAssertNil(f.store.pendingAttachments(for: f.directA.id).first?.annotation?.quote)
    }

    func testFailedSaveRetainsDraftAndRetryUpdatesTheSameAnnotationOnce() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original)
        let view = try content(controller), file = f.store.attachmentFileURL(original), before = try Data(contentsOf: file)
        press(try await control("Edit Comment", in: view))
        try await editComment("Retry this comment", in: view)
        let directory = f.repository.attachmentsDirectory(conversationID: original.conversationID)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        press(try await control("Save", in: view))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let field = try await editor(in: view); XCTAssertEqual(field.string, "Retry this comment")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.annotation?.comment, "First comment")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        press(try await control("Save", in: view))
        _ = try await control("Retry this comment", in: view)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).map(\.id), [original.id])
    }

    func testSendingAnAnnotationEndsEditingAndRejectsARetiredSaveAction() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original)
        let view = try content(controller), file = f.store.attachmentFileURL(original), before = try Data(contentsOf: file)
        press(try await control("Edit Comment", in: view))
        try await editComment("Too late to edit", in: view)
        let save = try await control("Save", in: view)
        f.store.sendDraft(to: f.directA.id)
        try await wait { !self.hasControl("Save", in: view) && !self.hasControl("Edit Comment", in: view) }
        press(save)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).last?.attachments, [original.id])
        _ = try await control("First comment", in: view)
    }

    func testReadOnlyPreviewHasNoEditorAndClosingReleasesThePanel() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original, editable: false)
        let view = try content(controller), panel = try XCTUnwrap(controller.window)
        _ = try await control("First comment", in: view)
        XCTAssertFalse(hasControl("Edit Comment", in: view))
        panel.cancelOperation(nil)
        XCTAssertNil(controller.window); XCTAssertFalse(panel.isVisible)
        controller.close(); XCTAssertNil(controller.window)
    }

    func testEditingAfterConversationSwitchKeepsTheOriginalDraft() async throws {
        let f = try fixture(), original = try note(f), controller = try preview(f, original)
        let view = try content(controller)
        f.store.selectedConversationID = f.directB.id; f.store.setDraft("Other conversation", for: f.directB.id)
        press(try await control("Edit Comment", in: view)); try await editComment("Original conversation edit", in: view)
        press(try await control("Save", in: view))
        _ = try await control("Original conversation edit", in: view)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.id, original.id)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty)
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Other conversation")
    }

    func testMissingRegionImageShowsFallbackAndFailedEditPreservesTheComment() async throws {
        let f = try fixture(), original = try note(f, region: true)
        try FileManager.default.removeItem(at: f.store.attachmentFileURL(original))
        let controller = try preview(f, original), view = try content(controller)
        _ = try await control("The saved image is unavailable.", in: view)
        press(try await control("Edit Comment", in: view)); try await editComment("Cannot lose the image", in: view)
        press(try await control("Save", in: view))
        let field = try await editor(in: view); XCTAssertEqual(field.string, "Cannot lose the image")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.annotation?.comment, "First comment")
    }

    func testCurrentAndLegacyRegionPreviewsReadSavedImagesWithoutRewritingFiles() async throws {
        let f = try fixture()
        for version in [1, 2] {
            let original = try note(f, region: true, version: version)
            let file = f.store.attachmentFileURL(original), before = try Data(contentsOf: file)
            XCTAssertNotNil(AnnotationPreviewContent.image(for: original, url: file))
            let controller = try preview(f, original), view = try content(controller)
            _ = try await control("Saved preview with the annotated region outlined in orange", in: view)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
}
