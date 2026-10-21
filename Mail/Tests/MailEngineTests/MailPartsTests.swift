@testable import MailEngine
import SwiftMail
import XCTest

final class MailPartsTests: XCTestCase {
    private func message(_ name: String) throws -> Message {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures"))
        return try Message(emlData: Data(contentsOf: url))
    }

    private func records(_ name: String) throws -> [PartRecord] { try message(name).parts.map(PartRecord.init) }

    /// When a mail has plain text and HTML, the plain text is the body and neither counts as an attachment.
    func testAlternativePrefersPlainText() throws {
        let parts = try records("alternative")
        let body = try XCTUnwrap(MailParts.body(in: parts))
        XCTAssertEqual(body.contentType, "text/plain")
        XCTAssertEqual(MailParts.attachments(in: parts, excluding: body), [])
    }

    /// An invoice mail lists its PDF with the part number a bot uses to save it.
    func testMixedMailListsItsAttachment() throws {
        let parts = try records("mixed-attachment")
        let body = MailParts.body(in: parts)
        XCTAssertEqual(body?.contentType, "text/plain")
        let attachments = MailParts.attachments(in: parts, excluding: body)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.name, "faktura.pdf")
        XCTAssertEqual(attachments.first?.type, "application/pdf")
        XCTAssertEqual(attachments.first?.part, parts.first { $0.filename == "faktura.pdf" }?.section)
    }

    /// A scan with no text has no body, and its PDF is still listed.
    func testAttachmentOnlyMailHasNoBody() throws {
        let parts = try records("attachment-only")
        XCTAssertNil(MailParts.body(in: parts))
        XCTAssertEqual(MailParts.attachments(in: parts, excluding: nil).map(\.name), ["scan.pdf"])
    }

    /// An HTML-only mail uses its HTML part as the body.
    func testHTMLOnlyMailUsesHTML() throws {
        XCTAssertEqual(MailParts.body(in: try records("html-only"))?.contentType, "text/html")
    }

    /// Quoted-printable ISO-8859-2 text arrives as proper Czech, with the charset taken from the part.
    func testQuotedPrintableLatin2Decodes() throws {
        let message = try message("qp-latin2")
        let part = try XCTUnwrap(message.parts.first)
        let record = PartRecord(part)
        XCTAssertEqual(record.charset?.lowercased(), "iso-8859-2")
        let decoded = MailText.decode(try XCTUnwrap(part.decodedData()), charset: record.charset)
        XCTAssertEqual(decoded.trimmingCharacters(in: .whitespacesAndNewlines), "Příliš žluťoučký kůň")
        XCTAssertEqual(message.subject, "Příliš žluťoučký kůň")
    }

    /// A text part that SwiftMail named after its Content-ID is still the body, because that name is not a filename the sender gave.
    func testTextPartNamedAfterItsContentIDStaysTheBody() {
        // What SwiftMail builds from IMAP for a nameless part: the Content-ID keeps its angle brackets, the invented filename has none.
        let part = MessagePart(sectionString: "1", contentType: "text/html; charset=utf-8", filename: "root@x", contentId: "<root@x>")
        let parts = [PartRecord(part)]
        let body = MailParts.body(in: parts)
        XCTAssertEqual(body?.contentType, "text/html")
        XCTAssertEqual(MailParts.attachments(in: parts, excluding: body), [])
    }

    /// A text part that is neither plain text nor HTML, such as a calendar invite, is an attachment even without a filename.
    func testOtherTextPartsAreAttachments() {
        let parts = [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 10),
                     PartRecord(section: "2", contentType: "text/calendar", charset: "utf-8", disposition: nil, filename: nil, size: 300)]
        let body = MailParts.body(in: parts)
        XCTAssertEqual(body?.section, "1")
        XCTAssertEqual(MailParts.attachments(in: parts, excluding: body), [AttachmentInfo(part: "2", name: "part-2", type: "text/calendar", size: 300)])
    }

    /// A filename that differs from the Content-ID is the sender's own, so it is kept and a text part carrying one is an attachment, not the body.
    func testFilenameDifferingFromContentIDIsKept() {
        let notes = MessagePart(sectionString: "1", contentType: "text/plain; charset=utf-8", filename: "notes.txt", contentId: "<notes@x>")
        let logo = MessagePart(sectionString: "2", contentType: "image/png", disposition: "inline", filename: "logo.png", contentId: "<logo@x>")
        let parts = [PartRecord(notes), PartRecord(logo)]
        XCTAssertEqual(parts.map(\.filename), ["notes.txt", "logo.png"])
        XCTAssertNil(MailParts.body(in: parts))
        XCTAssertEqual(MailParts.attachments(in: parts, excluding: nil).map(\.name), ["notes.txt", "logo.png"])
    }
}
