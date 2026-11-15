import XCTest
@testable import NoodleCore

/// What a paste into the composer attaches, in every app: files first, then a picture, then text long enough to
/// take over the conversation, or any text when asked to paste as an attachment. Anything else pastes as text.
final class PastedAttachmentsTests: XCTestCase {
    func testFilesThenPicturesThenLongTextBecomeAttachments() throws {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let png = Data([0x89, 0x50]), tiff = Data([0x4D, 0x4D])
        guard case .file(let url)? = AttachmentTransfer.pastedPayloads(fileURLs: [file], png: png, tiff: tiff, text: "x",
                                                                        textAsAttachment: false)?.first else { return XCTFail("file") }
        XCTAssertEqual(url, file)
        guard case .data(_, let name, let type)? = AttachmentTransfer.pastedPayloads(fileURLs: [], png: png, tiff: tiff, text: nil,
                                                                                    textAsAttachment: false)?.first else { return XCTFail("png") }
        XCTAssertEqual(name, "Pasted Image.png"); XCTAssertEqual(type, "image/png")
        guard case .data(_, let tiffName, _)? = AttachmentTransfer.pastedPayloads(fileURLs: [], png: nil, tiff: tiff, text: nil,
                                                                                 textAsAttachment: false)?.first else { return XCTFail("tiff") }
        XCTAssertEqual(tiffName, "Pasted Image.tiff")
        XCTAssertNil(AttachmentTransfer.pastedPayloads(fileURLs: [], png: nil, tiff: nil, text: "Short note", textAsAttachment: false))
        let long = String(repeating: "line\n", count: 20)
        guard case .data(_, let textName, let textType)? = AttachmentTransfer.pastedPayloads(fileURLs: [], png: nil, tiff: nil, text: long,
                                                                                            textAsAttachment: false)?.first else { return XCTFail("text") }
        XCTAssertEqual(textName, "Pasted Text.txt"); XCTAssertEqual(textType, "text/plain")
        XCTAssertNotNil(AttachmentTransfer.pastedPayloads(fileURLs: [], png: nil, tiff: nil, text: "Short note", textAsAttachment: true))
        XCTAssertNil(AttachmentTransfer.pastedPayloads(fileURLs: [], png: nil, tiff: nil, text: nil, textAsAttachment: true))
    }
}
