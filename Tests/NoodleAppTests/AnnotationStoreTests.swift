import AppKit
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class AnnotationStoreTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func source(_ f: StoreFixture) throws -> ConversationAttachment {
        try f.repository.importAttachment(data: Data("Original document".utf8), originalFilename: "Document.txt",
            into: f.directA.id, mediaType: "text/plain")
    }
    private func note(_ f: StoreFixture, region: Bool = false) throws -> ConversationAttachment {
        let source = try source(f)
        let annotation = AttachmentAnnotation(source: source, quote: region ? nil : "Original", comment: "First comment",
            region: region ? .init(x: 0.1, y: 0.2, width: 0.4, height: 0.5) : nil)
        let snapshot = region ? NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        } : nil
        try f.store.saveAnnotation(annotation, content: AnnotationContent.data(for: annotation, snapshot: snapshot), source: source)
        return try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
    }

    func testSavingAndEditingAfterConversationSwitchStaysWithOriginalDraft() throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directB.id
        f.store.setDraft("Other conversation", for: f.directB.id)
        let original = try note(f)
        let edited = try f.store.reviseAnnotationComment(original, comment: "  Revised comment  ")
        XCTAssertEqual(edited.conversationID, f.directA.id)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.annotation?.comment, "Revised comment")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).map(\.id), [original.id])
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty)
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Other conversation")
        XCTAssertEqual(try String(contentsOf: f.store.attachmentFileURL(edited), encoding: .utf8), edited.annotation?.textRepresentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.attachmentFileURL(original).path))
    }

    func testOpenPreviewCannotEditAnAnnotationAfterItIsSent() throws {
        let f = try fixture(), original = try note(f)
        XCTAssertTrue(f.store.canEditAnnotation(original))
        let bytes = try Data(contentsOf: f.store.attachmentFileURL(original))
        f.store.sendDraft(to: f.directA.id)
        XCTAssertFalse(f.store.canEditAnnotation(original))
        XCTAssertThrowsError(try f.store.reviseAnnotationComment(original, comment: "Late preview edit"))
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(original)), bytes)
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).last?.attachments, [original.id])
    }

    func testFailedAnnotationWriteKeepsPreviousDraftAndCanRetry() throws {
        let f = try fixture(), original = try note(f)
        let file = f.store.attachmentFileURL(original), before = try Data(contentsOf: file)
        let directory = f.repository.attachmentsDirectory(conversationID: f.directA.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try f.store.reviseAnnotationComment(original, comment: "Unwritable change"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.annotation?.comment, "First comment")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let edited = try f.store.reviseAnnotationComment(original, comment: "Successful retry")
        XCTAssertEqual(edited.annotation?.comment, "Successful retry")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).count, 1)
    }

    func testMissingRegionImageCannotBeReplacedWithEmptyContent() throws {
        let f = try fixture(), original = try note(f, region: true)
        let metadata = f.repository.attachmentsDirectory(conversationID: f.directA.id).appendingPathComponent(original.id.uuidString.lowercased() + ".json")
        let before = try Data(contentsOf: metadata)
        try FileManager.default.removeItem(at: f.store.attachmentFileURL(original))
        XCTAssertThrowsError(try f.store.reviseAnnotationComment(original, comment: "Missing image"))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.annotation?.comment, "First comment")
    }

    func testStalePreviewEditCannotOverwriteNewerComment() throws {
        let f = try fixture(), original = try note(f)
        let edited = try f.store.reviseAnnotationComment(original, comment: "Newer comment")
        XCTAssertThrowsError(try f.store.reviseAnnotationComment(original, comment: "Stale comment"))
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).first?.storedFilename, edited.storedFilename)
        XCTAssertEqual(try f.repository.loadAttachments(conversationID: f.directA.id).first { $0.id == original.id }?.annotation?.comment, "Newer comment")
    }

    func testDeletedSourceCannotLeaveAnOrphanAnnotationInDraft() throws {
        let f = try fixture(), source = try source(f)
        let annotation = AttachmentAnnotation(source: source, quote: "Original", comment: "Keep reference")
        try f.repository.removeAttachment(source)
        XCTAssertThrowsError(try f.store.saveAnnotation(annotation, content: Data(annotation.textRepresentation.utf8), source: source))
        XCTAssertTrue(f.store.pendingAttachments(for: f.directA.id).isEmpty)
        XCTAssertTrue(try f.repository.loadAttachments(conversationID: f.directA.id).isEmpty)
    }
}
