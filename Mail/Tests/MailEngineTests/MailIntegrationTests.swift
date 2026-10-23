import MailEngine
import SwiftMail
import XCTest

final class MailIntegrationTests: XCTestCase {
    private func account(imapPort: Int, smtpPort: Int = 1) -> MailAccount {
        MailAccount(address: "borek@example.com", displayName: "Bořek", username: "testuser",
                    imap: MailServer(host: "127.0.0.1", port: imapPort, security: .plainText),
                    smtp: MailServer(host: "127.0.0.1", port: smtpPort, security: .plainText), saveSentCopy: false)
    }

    /// A Maildir the fake IMAP server serves; its folder is removed when the test ends.
    private func maildir(with messages: [String]) throws -> URL {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: top) }
        let root = top.appendingPathComponent("Maildir")
        let cur = root.appendingPathComponent("cur")
        try FileManager.default.createDirectory(at: cur, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"), withIntermediateDirectories: true)
        for (index, message) in messages.enumerated() {
            try Data(message.utf8).write(to: cur.appendingPathComponent(String(format: "%03d.eml", index + 1)))
        }
        return root
    }

    private func mail(_ number: Int) -> String {
        """
        From: Ada <ada@example.com>
        To: Borek <borek@example.com>
        Subject: Invoice \(number)
        Date: Wed, 30 Sep 2026 0\(number):00:00 +0000
        Message-ID: <m\(number)@example.com>
        Content-Type: text/plain; charset=utf-8

        Dobrý den, faktura \(number).
        """
    }

    /// Against a real IMAP conversation, a list is newest first and reading returns the text.
    func testListAndReadOverIMAP() async throws {
        let server = try IMAPTestServer(host: "localhost", port: 0, username: "testuser", password: "testpass",
                                        maildirURL: try maildir(with: [mail(1), mail(2), mail(3)]))
        try server.start()
        try await server.run {
            let session = try MailSession(account: account(imapPort: server.port), password: "testpass")
            var query = MessageQuery()
            query.limit = 2
            let rows = try await session.list(query)
            XCTAssertEqual(rows.map(\.uid), [3, 2])
            XCTAssertEqual(rows.first?.subject, "Invoice 3")
            XCTAssertEqual(rows.first?.from, "Ada <ada@example.com>")
            let detail = try await session.read(uid: 1)
            XCTAssertEqual(detail.text.trimmingCharacters(in: .whitespacesAndNewlines), "Dobrý den, faktura 1.")
            XCTAssertEqual(detail.subject, "Invoice 1")
            await session.close()
        }
    }

    /// Over a real SMTP conversation the mail arrives complete, and Bcc goes only to the envelope, never into the headers.
    func testSendOverSMTPKeepsBccOutOfHeaders() async throws {
        let server = SMTPTestServer(ehloCapabilities: ["8BITMIME", "AUTH PLAIN"])
        try server.start()
        try await server.run {
            let session = try MailSession(account: account(imapPort: 1, smtpPort: server.port), password: "testpass")
            let receipt = try await session.send(OutgoingMail(to: ["Ada <ada@example.com>"], bcc: ["archiv@example.com"],
                                                              subject: "Faktura", body: "Dobrý den"))
            XCTAssertFalse(receipt.savedToSent)
            let wire = try XCTUnwrap(server.receivedContentMessages.first)
            let text = String(decoding: wire, as: UTF8.self)
            XCTAssertFalse(text.lowercased().contains("bcc:"))
            XCTAssertFalse(receipt.messageId.isEmpty)
            XCTAssertTrue(text.contains(receipt.messageId))
            let received = try Message(emlData: wire)
            XCTAssertEqual(received.subject, "Faktura")
            XCTAssertTrue(server.recordedCommands.contains { $0.uppercased().contains("RCPT TO:<ARCHIV@EXAMPLE.COM>") })
        }
    }

    /// Even when the server offers 8BITMIME, a bot's body goes out as 7-bit CRLF lines of at most 998 octets with every lone-dot line stuffed, and neither smuggled headers nor the Bcc address reach the message, while RCPT TO still carries the Bcc.
    func testSentBytesAreSafeOnTheWire() async throws {
        let server = SMTPTestServer(ehloCapabilities: ["8BITMIME", "AUTH PLAIN"])
        try server.start()
        try await server.run {
            let session = try MailSession(account: account(imapPort: 1, smtpPort: server.port), password: "testpass")
            // 960 characters on one line, 1,320 octets in UTF-8.
            let paragraph = String(repeating: "Příliš žluťoučký kůň úpěl ďábelské ódy. ", count: 24)
            let body = "Dobrý den,\n\nposílám fakturu.\r.\rKonec\n.\nKonec2\n" + paragraph
            _ = try await session.send(OutgoingMail(to: ["Ada <ada@example.com>"], bcc: ["archiv@example.com"],
                                                    subject: "Faktura\r\nBcc: evil@example.com", body: body,
                                                    inReplyTo: "<orig@example.com>\r\nX-Evil: 1"))
            XCTAssertEqual(server.receivedContentMessages.count, 1)
            let wire = try XCTUnwrap(server.receivedContentMessages.first)
            let bytes = [UInt8](wire)
            let bareCR = bytes.indices.filter { bytes[$0] == 0x0D && ($0 + 1 == bytes.count || bytes[$0 + 1] != 0x0A) }
            let bareLF = bytes.indices.filter { bytes[$0] == 0x0A && ($0 == 0 || bytes[$0 - 1] != 0x0D) }
            XCTAssertEqual(bareCR.count, 0, "bare CR")
            XCTAssertEqual(bareLF.count, 0, "bare LF")
            XCTAssertFalse(bytes.contains { $0 >= 0x80 }, "8-bit octets")
            let text = String(decoding: wire, as: UTF8.self)
            XCTAssertLessThanOrEqual(text.components(separatedBy: "\r\n").map(\.utf8.count).max() ?? 0, 998)
            // The test server records the content before it undoes dot-stuffing, so each lone-dot line shows up as "..".
            XCTAssertEqual(text.components(separatedBy: "\r\n..\r\n").count - 1, 2, "lone-dot lines stuffed")
            let headerLines = (text.components(separatedBy: "\r\n\r\n").first ?? "").components(separatedBy: "\r\n")
            XCTAssertFalse(headerLines.contains { $0.lowercased().hasPrefix("bcc:") || $0.lowercased().hasPrefix("x-evil:") }, "\(headerLines)")
            XCTAssertTrue(headerLines.contains("To: Ada <ada@example.com>"), "\(headerLines)")
            XCTAssertTrue(headerLines.contains("In-Reply-To: <orig@example.com>"), "\(headerLines)")
            XCTAssertFalse(text.lowercased().contains("archiv@example.com"))
            XCTAssertTrue(server.recordedCommands.contains { $0.uppercased().contains("RCPT TO:<ARCHIV@EXAMPLE.COM>") })
            XCTAssertFalse(server.recordedCommands.contains { $0.uppercased().hasPrefix("RCPT TO:<EVIL") })
            let received = try Message(emlData: unstuffed(wire))
            XCTAssertEqual(received.subject, "Faktura Bcc: evil@example.com")
            XCTAssertEqual(received.bcc, [])
            XCTAssertEqual(received.textBody, "Dobrý den,\r\n\r\nposílám fakturu.\r\n.\r\nKonec\r\n.\r\nKonec2\r\n" + paragraph)
        }
    }

    /// The message as the receiving server keeps it: a line that starts with two dots loses one, which the test server leaves undone.
    private func unstuffed(_ wire: Data) -> Data {
        var result = Data()
        var atLineStart = true
        var bytes = wire.makeIterator()
        while let byte = bytes.next() {
            if atLineStart, byte == 0x2E, let next = bytes.next() {
                result.append(byte)
                if next != 0x2E { result.append(next) }
                atLineStart = next == 0x0A
                continue
            }
            result.append(byte)
            atLineStart = byte == 0x0A
        }
        return result
    }
}
