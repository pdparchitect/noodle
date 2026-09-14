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

    func testDroppedDocumentsLoadFromDataAndFileRepresentations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentTransferTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, UTType)] = [
            ("README.md", UTType(filenameExtension: "md")!),
            ("Notes.txt", .plainText), ("Page.html", .html),
            ("Script.swift", .swiftSource), ("Settings.json", .json),
            ("Unknown.custom-extension", .data), ("LICENSE", .data)
        ]
        for (filename, type) in cases {
            let bytes = Data("Original bytes for \(filename)\n".utf8)
            let url = root.appendingPathComponent(filename)
            try bytes.write(to: url)
            for fileRepresentation in [false, true] {
                let provider = NSItemProvider()
                provider.suggestedName = filename
                if fileRepresentation {
                    provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                        fileOptions: [], visibility: .all) { completion in
                        completion(url, false, nil)
                        return nil
                    }
                } else {
                    register(type, data: bytes, on: provider)
                }
                guard case .data(let received, let name, let mediaType) = try await AttachmentTransfer.load(provider, context: .drop) else {
                    return XCTFail("Expected document bytes for \(filename)")
                }
                XCTAssertEqual(received, bytes)
                XCTAssertEqual(name, filename)
                XCTAssertEqual(mediaType, type.preferredMIMEType ?? "application/octet-stream")
            }
        }
    }

    func testDroppedFileURLWinsOverTextRepresentationForEveryFileExtension() async throws {
        for filename in ["README.md", "Notes.txt", "data.unknown", "LICENSE"] {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            let provider = NSItemProvider(object: url as NSURL)
            register(.plainText, data: Data("alternative text".utf8), on: provider)
            for context in [AttachmentTransfer.Context.drop, .paste] {
                guard case .file(let received) = try await AttachmentTransfer.load(provider, context: context) else {
                    return XCTFail("Expected the original file URL")
                }
                XCTAssertEqual(received, url.standardizedFileURL)
            }
        }
    }

    func testDroppedFileURLsLoadFromPasteboardRepresentations() async throws {
        let url = URL(fileURLWithPath: "/tmp/Notes with spaces.txt")
        let dataProvider = NSItemProvider()
        register(.fileURL, data: Data(url.absoluteString.utf8), on: dataProvider)
        let itemProvider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        for provider in [dataProvider, itemProvider] {
            guard case .file(let received) = try await AttachmentTransfer.load(provider, context: .drop) else {
                return XCTFail("Expected a local file URL")
            }
            XCTAssertEqual(received, url.standardizedFileURL)
        }
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

    func testDroppedBinaryDataWinsOverAlternativeText() async throws {
        let provider = NSItemProvider()
        register(.plainText, data: Data("description".utf8), on: provider)
        register(.data, data: Data([0, 255, 17]), on: provider)
        guard case .data(let bytes, _, _) = try await AttachmentTransfer.load(provider, context: .drop) else {
            return XCTFail("Expected the file bytes")
        }
        XCTAssertEqual(bytes, Data([0, 255, 17]))
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
