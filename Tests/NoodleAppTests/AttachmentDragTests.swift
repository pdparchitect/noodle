import AppKit
import NoodleCore
import UniformTypeIdentifiers
import XCTest
@testable import Noodle

final class AttachmentDragTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDragTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func attachment(_ filename: String, mediaType: String = "application/octet-stream") -> ConversationAttachment {
        .init(conversationID: UUID(), originalFilename: filename, storedFilename: "stored-file",
              mediaType: mediaType, byteCount: 7)
    }

    private func fileURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = object as? URL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: AttachmentTransferError.unsupportedItem) }
            }
        }
    }

    func testFileDropPreservesDisplayNameAndDoesNotExposeConversationStorage() async throws {
        let root = try directory(), source = root.appendingPathComponent("stored-uuid.pdf")
        let bytes = Data("original document".utf8)
        try bytes.write(to: source)
        let item = attachment("Quarterly report — final.pdf", mediaType: "application/pdf")
        let provider = try AttachmentDrag.provider(for: item, fileURL: source, temporaryDirectory: root)
        XCTAssertEqual(provider.suggestedName, item.originalFilename)
        let exported = try await fileURL(provider)
        XCTAssertEqual(exported.lastPathComponent, item.originalFilename)
        XCTAssertNotEqual(exported, source)
        XCTAssertEqual(try Data(contentsOf: exported), bytes)

        // Apps are free to edit or move the exported file. Neither operation
        // may change the attachment that remains in the conversation.
        try Data("edited elsewhere".utf8).write(to: exported)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try FileManager.default.moveItem(at: exported, to: root.appendingPathComponent("Dropped.pdf"))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testTypedConsumersReceiveOriginalBytesAfterDraftIsRemoved() async throws {
        let root = try directory()
        for (filename, type) in [("Image.png", UTType.png), ("Image.unusual", .png), ("Document.pdf", .pdf),
                                 ("Recording.m4a", .mpeg4Audio), ("Archive.zip", .zip), ("Opaque", .data)] {
            let source = root.appendingPathComponent(UUID().uuidString)
            let bytes = Data("complete original \(filename)".utf8)
            try bytes.write(to: source)
            let provider = try AttachmentDrag.provider(
                for: attachment(filename, mediaType: type.preferredMIMEType ?? "application/octet-stream"),
                fileURL: source, temporaryDirectory: root)
            try FileManager.default.removeItem(at: source)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(type.identifier))
            let received: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: AttachmentTransferError.unsupportedItem) }
                }
            }
            XCTAssertEqual(received, bytes)
            let exported = try await fileURL(provider)
            XCTAssertEqual(try Data(contentsOf: exported), bytes)
        }
    }

    func testSameFilenameDragsStayIndependentAndRoundTripThroughDropImporter() async throws {
        let root = try directory(), source = root.appendingPathComponent("stored-file")
        let item = attachment("Notes.txt", mediaType: "text/plain")
        try Data("first".utf8).write(to: source)
        let first = try AttachmentDrag.provider(for: item, fileURL: source, temporaryDirectory: root)
        try Data("second".utf8).write(to: source)
        let second = try AttachmentDrag.provider(for: item, fileURL: source, temporaryDirectory: root)
        for (provider, expected) in [(first, "first"), (second, "second")] {
            guard case .file(let url) = try await AttachmentTransfer.load(provider) else {
                return XCTFail("Noodle must import the file, including plain-text documents")
            }
            XCTAssertEqual(url.lastPathComponent, "Notes.txt")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
        }
    }

    func testMissingFilesDirectoriesAndSymlinksCannotProduceDrags() throws {
        let root = try directory(), source = root.appendingPathComponent("missing.txt")
        let item = attachment("Notes.txt")
        XCTAssertThrowsError(try AttachmentDrag.provider(for: item, fileURL: source, temporaryDirectory: root))
        XCTAssertThrowsError(try AttachmentDrag.provider(for: item, fileURL: root, temporaryDirectory: root))
        let target = root.appendingPathComponent("target.txt")
        try Data("contents".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        XCTAssertThrowsError(try AttachmentDrag.provider(for: item, fileURL: source, temporaryDirectory: root))
    }

    func testExportFilenameCannotEscapeItsTemporaryDirectory() async throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data("contents".utf8).write(to: source)
        let provider = try AttachmentDrag.provider(for: attachment("../../Report.pdf"), fileURL: source, temporaryDirectory: root)
        let url = try await fileURL(provider)
        XCTAssertEqual(url.lastPathComponent, "Report.pdf")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path, root.path)
        for name in ["", ".", ".."] {
            XCTAssertThrowsError(try AttachmentDrag.provider(for: attachment(name), fileURL: source, temporaryDirectory: root))
        }
    }

    func testSaveWritesTheOriginalBytesAndReplacesTheChosenFile() throws {
        let root = try directory(), source = root.appendingPathComponent("stored-file")
        let destination = root.appendingPathComponent("Chosen.pdf")
        try Data("original".utf8).write(to: source)
        try Data("older file the person chose to replace".utf8).write(to: destination)
        try AttachmentDrag.save(fileURL: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertThrowsError(try AttachmentDrag.save(fileURL: root, to: root.appendingPathComponent("Folder")))
    }

    /// Copy on a shader in a conversation: its file, named as it was sent and apart from conversation storage,
    /// with its source under the Metal type, so it pastes into the Background sheet, Finder or another conversation.
    @MainActor func testShaderCopiesAsItsFileWithTheMetalType() throws {
        let root = try directory(), source = root.appendingPathComponent("stored-file.metal")
        try "[[ stitchable ]] half4 glow(float2 position) { return half4(1); }".write(to: source, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(AttachmentDrag.copy(attachment("Aurora.metal", mediaType: "text/plain"), fileURL: source, to: pasteboard))

        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(files.map(\.lastPathComponent), ["Aurora.metal"])
        XCTAssertNotEqual(files.first?.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(files.first.flatMap { try? Data(contentsOf: $0) }, try Data(contentsOf: source))
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType("com.apple.metal")), try Data(contentsOf: source))
    }

    func testOnlyFilesOfferSaving() {
        XCTAssertTrue(attachment("Report.pdf").isSavable)
        for url in [URL(string: "https://example.com")!, CompanionLink.noodlet(UUID()).url] {
            XCTAssertFalse(ConversationAttachment(conversationID: UUID(), originalFilename: "Link.webloc",
                storedFilename: "stored-file", mediaType: "application/x-webloc", byteCount: 7, url: url).isSavable)
        }
    }

    @MainActor func testStoreReportsMissingAttachmentWithoutOfferingBrokenFileURL() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let provider = fixture.store.attachmentDragProvider(attachment("Missing.pdf"))
        XCTAssertTrue(provider.registeredTypeIdentifiers.isEmpty)
        XCTAssertTrue(fixture.store.errorMessage?.hasPrefix("The attachment could not be dragged:") == true)
    }
}
