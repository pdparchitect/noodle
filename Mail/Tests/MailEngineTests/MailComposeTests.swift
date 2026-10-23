@testable import MailEngine
import SwiftMail
import XCTest

final class MailComposeTests: XCTestCase {
    private let account = MailAccount(address: "borek@mail.example.org", displayName: "Bořek", username: "borek@mail.example.org",
        imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
        smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls))

    /// True when the text holds a CR or LF. It looks at unicode scalars because Swift reads "\r\n" as one Character, which is neither "\r" nor "\n".
    private func hasLineBreak(_ text: String) -> Bool { text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }

    /// The mail comes from the account, goes to the people asked for, and gets a Message-ID on the account's domain.
    func testMailHasSenderRecipientsAndMessageID() throws {
        let email = try MailCompose.email(OutgoingMail(to: ["Ada <ada@example.com>"], cc: ["petr@example.cz"], bcc: ["archiv@example.cz"],
                                                       subject: "Faktura", body: "Dobrý den"), from: account)
        XCTAssertEqual(email.sender.address, "borek@mail.example.org")
        XCTAssertEqual(email.sender.name, "Bořek")
        XCTAssertEqual(email.recipients.map(\.address), ["ada@example.com"])
        XCTAssertEqual(email.ccRecipients.map(\.address), ["petr@example.cz"])
        XCTAssertEqual(email.bccRecipients.map(\.address), ["archiv@example.cz"])
        XCTAssertEqual(email.subject, "Faktura")
        XCTAssertEqual(email.textBody, "Dobrý den")
        XCTAssertTrue(try XCTUnwrap(email.messageID).description.hasSuffix("@mail.example.org>"))
    }

    /// Every line break in the body leaves as CRLF, whether the bot wrote CRLF, LF or a lone CR.
    func testBodyLineBreaksBecomeCRLF() throws {
        let email = try MailCompose.email(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "a\nb\r\rc\r\nd\n\re\r\r\nf\r"), from: account)
        XCTAssertEqual(email.textBody, "a\r\nb\r\n\r\nc\r\nd\r\n\r\ne\r\n\r\nf\r\n")
    }

    /// Line breaks in the subject, a filename or In-Reply-To cannot add headers.
    func testHeaderValuesStayOnOneLine() throws {
        let email = try MailCompose.email(OutgoingMail(to: ["ada@example.com"], subject: "Hi\r\nBcc: evil@example.com", body: "x",
            inReplyTo: "<orig@example.com>\r\nX-Evil: 1",
            attachments: [OutgoingAttachment(filename: "a\nb.pdf", mimeType: "application/pdf", data: Data([1]))]), from: account)
        XCTAssertEqual(email.subject, "Hi Bcc: evil@example.com")
        XCTAssertFalse(email.additionalHeaders?.values.contains(where: hasLineBreak) ?? false)
        XCTAssertEqual(email.additionalHeaders?["In-Reply-To"], "<orig@example.com>")
        XCTAssertEqual(email.attachments?.first?.filename, "a b.pdf")
    }

    /// A reply threads: In-Reply-To and References carry the original Message-ID.
    func testReplyCarriesThreadHeaders() throws {
        let email = try MailCompose.email(OutgoingMail(to: ["ada@example.com"], subject: "Re: Faktura", body: "Díky",
                                                       inReplyTo: "<orig@example.com>"), from: account)
        XCTAssertEqual(email.additionalHeaders?["In-Reply-To"], "<orig@example.com>")
        XCTAssertEqual(email.additionalHeaders?["References"], "<orig@example.com>")
    }

    /// A mail with nobody to send to, or with an address that isn't one, is refused before anything happens.
    func testBadRecipientsAreRefused() {
        XCTAssertThrowsError(try MailCompose.email(OutgoingMail(to: [], subject: "x", body: "x"), from: account)) {
            XCTAssertEqual($0 as? MailEngineError, .noRecipients)
        }
        XCTAssertThrowsError(try MailCompose.email(OutgoingMail(to: ["not an address"], subject: "x", body: "x"), from: account)) {
            XCTAssertEqual($0 as? MailEngineError, .invalidAddress("not an address"))
        }
    }

    /// A recipient with a line break in it is accepted with the break turned into a space, and its address is kept.
    func testLineBreaksInARecipientAreFlattened() throws {
        // The first one parses as it stands (a line break followed by a space is folding white space); the other two are refused unless flattened.
        let email = try MailCompose.email(OutgoingMail(to: ["Ada\r\n <ada@example.com>", "Ada\r\nBob <ada@example.com>", "ada@example.com\n"],
                                                       subject: "x", body: "x"), from: account)
        XCTAssertEqual(email.recipients.map(\.address), ["ada@example.com", "ada@example.com", "ada@example.com"])
        XCTAssertFalse(email.recipients.contains { hasLineBreak($0.name ?? "") })
        XCTAssertEqual(email.recipients.map(\.name), ["Ada", "Ada Bob", nil])
    }

    /// A display name written as an encoded word that decodes to a line break cannot carry one into the mail.
    func testEncodedRecipientNamesStayOnOneLine() throws {
        // The same name, "Ada\r\nBcc: evil@x", once in quoted-printable and once in base64.
        let email = try MailCompose.email(OutgoingMail(to: ["=?UTF-8?Q?Ada=0D=0ABcc=3A_evil=40x?= <ada@example.com>",
                                                            "=?UTF-8?B?QWRhDQpCY2M6IGV2aWxAeA==?= <ada@example.com>"],
                                                       subject: "x", body: "x"), from: account)
        XCTAssertEqual(email.recipients.map(\.address), ["ada@example.com", "ada@example.com"])
        XCTAssertFalse(email.recipients.contains { hasLineBreak($0.name ?? "") })
        XCTAssertEqual(email.recipients.map(\.name), ["Ada Bcc: evil@x", "Ada Bcc: evil@x"])
    }

    /// A line break in the account's display name cannot reach the From header either.
    func testSenderNameStaysOnOneLine() throws {
        var odd = account
        odd.displayName = "Bo\r\nBcc: x@y.cz"
        let email = try MailCompose.email(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"), from: odd)
        XCTAssertFalse(hasLineBreak(email.sender.name ?? ""))
        XCTAssertEqual(email.sender.name, "Bo Bcc: x@y.cz")
        XCTAssertEqual(email.sender.address, "borek@mail.example.org")
    }
}
