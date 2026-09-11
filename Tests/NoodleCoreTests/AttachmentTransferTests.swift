import XCTest
import UniformTypeIdentifiers
@testable import NoodleCore

final class AttachmentTransferTests: XCTestCase {
    func testBestAvailableFormatIsChosenRegardlessOfRegistrationOrder() async throws {
        let formats: [UTType] = [.png, .jpeg, .tiff, .pdf, .mpeg4Movie, .mp3, .zip, .data]
        for index in formats.indices.dropLast() {
            let offered = Array(formats[index...])
            for order in [offered, Array(offered.reversed())] {
                let provider = NSItemProvider()
                for type in order { register(type, data: Data(type.identifier.utf8), on: provider) }
                let payload = try await AttachmentTransfer.load(provider)
                guard case .data(let bytes, _, let mediaType) = payload else {
                    return XCTFail("Expected an in-memory attachment")
                }
                XCTAssertEqual(bytes, Data(formats[index].identifier.utf8))
                XCTAssertEqual(mediaType, formats[index].preferredMIMEType)
            }
        }
    }

    func testFilenameFallbacksAndExistingExtensionsArePreserved() async throws {
        let cases: [(UTType, String?, String)] = [
            (.png, nil, "Pasted Image.png"),
            (.pdf, nil, "Attachment.pdf"),
            (.png, "   ", "Pasted Image.png"),
            (.pdf, "   ", "Attachment.pdf"),
            (.png, "/private/folder/screenshot", "screenshot.png"),
            (.pdf, "report.final.pdf", "report.final.pdf"),
            (.pdf, "  quarterly report  ", "quarterly report.pdf"),
            (.data, "opaque", "opaque")
        ]
        for (type, suggested, expected) in cases {
            let provider = NSItemProvider()
            provider.suggestedName = suggested
            register(type, data: Data([1, 2, 3]), on: provider)
            guard case .data(let bytes, let filename, let mediaType) = try await AttachmentTransfer.load(provider) else {
                return XCTFail("Expected an in-memory attachment")
            }
            XCTAssertEqual(filename, expected)
            XCTAssertEqual(bytes, Data([1, 2, 3]))
            XCTAssertEqual(mediaType, type.preferredMIMEType ?? "application/octet-stream")
        }
    }

    func testTextHTMLAndDirectoriesDoNotBecomeAttachments() async throws {
        for type in [UTType.plainText, .html, .directory] {
            let provider = NSItemProvider()
            register(type, data: Data("keep text in the composer".utf8), on: provider)
            await assertUnsupported(provider)
        }
        await assertUnsupported(NSItemProvider())
    }

    func testImageIsSelectedWhenClipboardAlsoOffersTextAndHTML() async throws {
        let provider = NSItemProvider()
        for type in [UTType.html, .plainText, .png] {
            register(type, data: Data(type.identifier.utf8), on: provider)
        }
        guard case .data(let bytes, _, let mediaType) = try await AttachmentTransfer.load(provider) else {
            return XCTFail("Expected image data")
        }
        XCTAssertEqual(bytes, Data(UTType.png.identifier.utf8))
        XCTAssertEqual(mediaType, "image/png")
    }

    func testProviderFailuresAreReportedInsteadOfCreatingEmptyAttachments() async {
        let provider = NSItemProvider()
        let failure = NSError(domain: "Noodle.AttachmentTransferTests", code: 17)
        provider.registerDataRepresentation(for: .pdf, visibility: .all) { completion in
            completion(nil, failure)
            return nil
        }
        do {
            _ = try await AttachmentTransfer.load(provider)
            XCTFail("A failed provider must not create an attachment")
        } catch {
            // NSItemProvider may wrap the original error; it must remain available for diagnosis.
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertTrue(error.domain == failure.domain || underlying?.domain == failure.domain)
        }
    }

    func testURLSchemesThatCannotBeDownloadedAreRejected() async {
        for value in ["ftp://files.invalid/report.pdf", "mailto:person@example.invalid", "data:text/plain,hello"] {
            let provider = NSItemProvider(object: URL(string: value)! as NSURL)
            await assertUnsupported(provider)
        }
    }

    private func register(_ type: UTType, data: Data, on provider: NSItemProvider) {
        provider.registerDataRepresentation(for: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }

    private func assertUnsupported(_ provider: NSItemProvider, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await AttachmentTransfer.load(provider)
            XCTFail("Expected an unsupported attachment error", file: file, line: line)
        } catch AttachmentTransferError.unsupportedItem {
            // Expected: the composer can leave ordinary text alone or explain the unsupported drop.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
