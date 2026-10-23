@testable import MailEngine
import SwiftMail
import XCTest

final class MailSessionTests: XCTestCase {
    private var imap: FakeIMAP!
    private var smtp: FakeSMTP!

    private func session(draftsFolder: String? = nil, sentFolder: String? = nil, saveSentCopy: Bool = true) -> MailSession {
        imap = imap ?? FakeIMAP()
        smtp = smtp ?? FakeSMTP()
        let account = MailAccount(address: "borek@mail.example.org", displayName: "Bořek", username: "borek@mail.example.org",
            imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls), smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls),
            draftsFolder: draftsFolder, sentFolder: sentFolder, saveSentCopy: saveSentCopy)
        return MailSession(account: account, password: "secret", imap: imap, smtp: smtp)
    }

    override func setUp() { imap = FakeIMAP(); smtp = FakeSMTP() }

    /// Review focus 5: a session refuses plain text to a real host for IMAP and SMTP alike, when it is made, before anything connects.
    func testSessionRefusesPlainTextToRealHosts() {
        func account(imap: MailServer, smtp: MailServer) -> MailAccount {
            MailAccount(address: "borek@mail.example.org", username: "borek@mail.example.org", imap: imap, smtp: smtp)
        }
        let imapTLS = MailServer(host: "imap.seznam.cz", port: 993, security: .tls)
        let smtpTLS = MailServer(host: "smtp.seznam.cz", port: 465, security: .tls)
        XCTAssertThrowsError(try MailSession(account: account(imap: MailServer(host: "imap.seznam.cz", port: 143, security: .plainText), smtp: smtpTLS),
                                             password: "secret")) {
            XCTAssertEqual($0 as? MailEngineError, .insecureServer(host: "imap.seznam.cz"))
        }
        XCTAssertThrowsError(try MailSession(account: account(imap: imapTLS, smtp: MailServer(host: "smtp.seznam.cz", port: 587, security: .plainText)),
                                             password: "secret")) {
            XCTAssertEqual($0 as? MailEngineError, .insecureServer(host: "smtp.seznam.cz"))
        }
    }

    /// A list is the newest messages first, in the folder asked for, signed in once.
    func testListIsNewestFirst() async throws {
        imap.records = (1...5).map { HeaderRecord.sample(uid: $0, subject: "M\($0)") }
        var query = MessageQuery()
        query.folder = "Faktury"
        query.limit = 2
        let s = session()
        let rows = try await s.list(query)
        XCTAssertEqual(rows.map(\.uid), [5, 4])
        XCTAssertEqual(rows.first?.subject, "M5")
        XCTAssertEqual(imap.selected, ["Faktury"])
        _ = try await s.list(query)
        XCTAssertEqual(imap.logins, 1)
    }

    /// Reading returns the decoded text and leaves the mail unread unless asked.
    func testReadDecodesAndOnlyMarksWhenAsked() async throws {
        imap.records = [HeaderRecord.sample(uid: 7, subject: "Faktura", parts: [PartRecord(section: "1", contentType: "text/plain", charset: "windows-1250", disposition: nil, filename: nil, size: 6)])]
        imap.partBytes["7:1"] = "Příliš".data(using: .windowsCP1250)
        let s = session()
        let detail = try await s.read(uid: 7)
        XCTAssertEqual(detail.text, "Příliš")
        XCTAssertEqual(imap.seen, [])
        _ = try await s.read(uid: 7, markRead: true)
        XCTAssertEqual(imap.seen, [7])
    }

    /// An HTML-only mail reads as plain text.
    func testReadConvertsHTML() async throws {
        imap.records = [HeaderRecord.sample(uid: 3, subject: "Shop", parts: [PartRecord(section: "1", contentType: "text/html", charset: "utf-8", disposition: nil, filename: nil, size: 30)])]
        imap.partBytes["3:1"] = Data("<p>Objednávka&nbsp;odeslána</p>".utf8)
        let detail = try await session().read(uid: 3)
        XCTAssertEqual(detail.text, "Objednávka odeslána")
    }

    /// A plain-text part that is blank gives way to the HTML beside it, so the mail doesn't read as empty; plain text with words in it stays the body.
    func testBlankPlainTextFallsBackToHTML() async throws {
        let alternative = [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 5),
                           PartRecord(section: "2", contentType: "text/html", charset: "utf-8", disposition: nil, filename: nil, size: 40)]
        imap.records = [HeaderRecord.sample(uid: 5, subject: "Shop", parts: alternative), HeaderRecord.sample(uid: 6, subject: "Shop", parts: alternative)]
        imap.partBytes["5:1"] = Data(" \r\n\t\r\n".utf8)
        imap.partBytes["5:2"] = Data("<p>Objednávka&nbsp;odeslána</p>".utf8)
        imap.partBytes["6:1"] = Data("Objednávka odeslána.".utf8)
        imap.partBytes["6:2"] = Data("<p>Jiný text</p>".utf8)
        let s = session()
        let blank = try await s.read(uid: 5)
        XCTAssertEqual(blank.text, "Objednávka odeslána")
        XCTAssertEqual(blank.attachments, [])
        let plain = try await s.read(uid: 6)
        XCTAssertEqual(plain.text, "Objednávka odeslána.")
    }

    /// A spam mail with a huge subject, sender and recipient lists reaches a bot cut down, in a list and in a read alike.
    func testListsAndReadsCapSubjectSenderAndRecipients() async throws {
        imap.records = [HeaderRecord(uid: 9, date: Date(timeIntervalSince1970: 1_790_755_209), from: String(repeating: "f", count: 1_000),
                                     to: (1...100).map { "to\($0)@example.com" }, cc: (1...30).map { "cc\($0)@example.com" },
                                     subject: String(repeating: "s", count: 5_000), messageId: "<9@example.com>", seen: false,
                                     parts: [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 4)])]
        imap.partBytes["9:1"] = Data("Text".utf8)
        let s = session()
        let rows = try await s.list(MessageQuery())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subject?.count, 300)
        XCTAssertEqual(row.from?.count, 300)
        XCTAssertEqual(row.subject?.last, "\u{2026}")
        XCTAssertEqual(row.from?.last, "\u{2026}")
        let detail = try await s.read(uid: 9)
        XCTAssertEqual(detail.subject?.count, 300)
        XCTAssertEqual(detail.from?.count, 300)
        XCTAssertEqual(detail.subject?.last, "\u{2026}")
        XCTAssertEqual(detail.from?.last, "\u{2026}")
        XCTAssertEqual(detail.to.count, 21)
        XCTAssertEqual(detail.to.first, "to1@example.com")
        XCTAssertEqual(detail.to.last, "\u{2026} and 80 more")
        XCTAssertEqual(detail.cc.count, 21)
        XCTAssertEqual(detail.cc.last, "\u{2026} and 10 more")
    }

    /// A spam mail with 60 attachments of huge names and types reaches a bot as the first 50, each cut down, and a count of the other 10;
    /// one with exactly 50 has no count. A list row still counts them all.
    func testReadKeepsTheFirstFiftyAttachmentsCutDownAndCountsTheRest() async throws {
        func parts(_ attachments: Int) -> [PartRecord] {
            [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 4)]
                + (0..<attachments).map {
                    PartRecord(section: "\($0 + 2)", contentType: "application/" + String(repeating: "x", count: 1_000), charset: nil,
                               disposition: "attachment", filename: String(repeating: "n", count: 1_000), size: 10)
                }
        }
        imap.records = [HeaderRecord.sample(uid: 9, subject: "Spam", parts: parts(60)), HeaderRecord.sample(uid: 8, subject: "Full", parts: parts(50))]
        imap.partBytes["9:1"] = Data("Text".utf8)
        imap.partBytes["8:1"] = Data("Text".utf8)
        let s = session()
        let detail = try await s.read(uid: 9)
        XCTAssertEqual(detail.attachments.map(\.part), (2...51).map(String.init))
        XCTAssertEqual(detail.attachmentsOmitted, 10)
        XCTAssertEqual(Set(detail.attachments.map(\.name.count)), [300])
        XCTAssertEqual(Set(detail.attachments.map(\.name.last)), ["\u{2026}"])
        XCTAssertEqual(Set(detail.attachments.map(\.type.count)), [300])
        let full = try await s.read(uid: 8)
        XCTAssertEqual(full.attachments.count, 50)
        XCTAssertNil(full.attachmentsOmitted)
        let rows = try await s.list(MessageQuery())
        XCTAssertEqual(rows.first { $0.uid == 9 }?.attachments, 60)
    }

    /// A Message-ID longer than a header line may be (998 octets) is left out rather than cut, because a cut ID names no message;
    /// one of exactly 998 octets is kept whole.
    func testAMessageIDOverTheLineLimitIsLeftOut() async throws {
        func record(uid: Int, messageId: String) -> HeaderRecord {
            HeaderRecord(uid: uid, date: nil, from: "ada@example.com", to: [], cc: [], subject: "Hi", messageId: messageId, seen: false,
                         parts: [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 4)])
        }
        let atLimit = "<" + String(repeating: "\u{E1}", count: 498) + ">"   // "á" is two octets in UTF-8: 998 octets
        let over = "<" + String(repeating: "a", count: 997) + ">"            // 999 octets
        imap.records = [record(uid: 7, messageId: atLimit), record(uid: 6, messageId: over)]
        imap.partBytes["7:1"] = Data("Text".utf8)
        imap.partBytes["6:1"] = Data("Text".utf8)
        let s = session()
        let kept = try await s.read(uid: 7)
        XCTAssertEqual(kept.messageId, atLimit)
        let left = try await s.read(uid: 6)
        XCTAssertNil(left.messageId?.utf8.count, "an ID of 999 octets is left out")
    }

    /// A missing message is a clear error, not an empty result.
    func testReadingAMissingMessageFails() async {
        do {
            _ = try await session().read(uid: 404)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .messageNotFound(uid: 404))
        }
    }

    /// Only a header for the UID asked for counts, so a server answering with another mail (UID FETCH * gives the newest) reads as a missing message, and nothing is marked read.
    func testAnotherMessagesHeaderIsAMissingMessage() async {
        imap.records = [HeaderRecord.sample(uid: 42, subject: "Newest")]
        imap.ignoresAskedUIDs = true
        imap.partBytes["7:1"] = Data("Nejnovější".utf8)   // the server answers part requests for 7 from that same mail
        let s = session()
        do {
            let detail = try await s.read(uid: 7, markRead: true)
            XCTFail("expected an error, got \(detail.subject ?? "") as message \(detail.uid)")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .messageNotFound(uid: 7))
        }
        XCTAssertEqual(imap.seen, [])
        do {
            let data = try await s.attachment(uid: 7, part: "1")
            XCTFail("expected an error, got \(data.count) bytes")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .messageNotFound(uid: 7))
        }
    }

    /// A draft goes to the folder the server marks as Drafts, flagged as a draft.
    func testDraftUsesTheMarkedFolder() async throws {
        imap.folderList = [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Rozepsan&AOk-", role: .drafts)]
        let receipt = try await session().draft(OutgoingMail(to: ["ada@example.com"], subject: "Návrh", body: "Text"))
        XCTAssertEqual(receipt.folder, "Rozepsan&AOk-")
        XCTAssertEqual(receipt.draftUid, 901)
        XCTAssertEqual(imap.appended.first?.flags, [.draft, .seen])
    }

    /// Review focus 1: localized folders without marks use the account's override; with none, the answer is folderNotFound, never INBOX.
    func testUnmarkedFoldersUseOverrideOrFail() async throws {
        imap.folderList = [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Rozepsan&AOk-", role: nil)]
        let receipt = try await session(draftsFolder: "Rozepsan&AOk-").draft(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
        XCTAssertEqual(receipt.folder, "Rozepsan&AOk-")
        imap = FakeIMAP()
        imap.folderList = [MailFolder(name: "INBOX", role: .inbox)]
        do {
            _ = try await session().draft(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .folderNotFound(role: "Drafts"))
            XCTAssertTrue(imap.appended.isEmpty)
        }
    }

    /// Sending delivers the mail and keeps a read copy in Sent with the same Message-ID.
    func testSendDeliversAndFilesACopy() async throws {
        imap.folderList = [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Odeslan&AOk-", role: .sent)]
        let receipt = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "Faktura", body: "Dobrý den"))
        XCTAssertEqual(smtp.sent.count, 1)
        XCTAssertEqual(smtp.logouts, 1)
        XCTAssertEqual(imap.appended.first?.folder, "Odeslan&AOk-")
        XCTAssertEqual(imap.appended.first?.flags, [.seen])
        XCTAssertFalse(receipt.messageId.isEmpty)
        XCTAssertTrue(headerLines(of: try XCTUnwrap(imap.appendedMessages.first)).contains("Message-Id: \(receipt.messageId)"))
        XCTAssertTrue(receipt.savedToSent)
    }

    /// A draft keeps its Bcc recipients in a Bcc header, so a person who sends it from webmail still reaches them.
    func testDraftKeepsTheBcc() async throws {
        imap.folderList = [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Drafts", role: .drafts)]
        _ = try await session().draft(OutgoingMail(to: ["ada@example.com"], bcc: ["archiv@example.com", "Petr <petr@example.cz>"],
                                                   subject: "Návrh", body: "Text"))
        let copy = try XCTUnwrap(imap.appendedMessages.first)
        XCTAssertTrue(headerLines(of: copy).contains("Bcc: archiv@example.com, petr@example.cz"), "\(headerLines(of: copy))")
        XCTAssertEqual(try Message(emlData: copy).bcc, ["archiv@example.com", "petr@example.cz"])
    }

    /// The Sent copy is byte for byte the mail that went out plus a Bcc header, while the mail itself has no Bcc header and names the Bcc recipient only in RCPT TO.
    func testSentCopyIsTheSentMailWithItsBcc() async throws {
        imap.folderList = [MailFolder(name: "Sent", role: .sent)]
        _ = try await session().send(OutgoingMail(to: ["ada@example.com"], bcc: ["archiv@example.com"], subject: "Faktura", body: "Dobrý den"))
        let sent = try XCTUnwrap(smtp.sentMessages.first)
        let copy = try XCTUnwrap(imap.appendedMessages.first)
        let sentText = String(decoding: sent.message, as: UTF8.self)
        XCTAssertTrue(headerLines(of: copy).contains("Bcc: archiv@example.com"), "\(headerLines(of: copy))")
        XCTAssertEqual(String(decoding: copy, as: UTF8.self).replacingOccurrences(of: "Bcc: archiv@example.com\r\n", with: ""), sentText)
        XCTAssertFalse(sentText.contains("archiv@example.com"))
        XCTAssertEqual(sent.recipients.map(\.address), ["ada@example.com", "archiv@example.com"])
    }

    /// The header lines of a message: everything before the first empty line.
    private func headerLines(of message: Data) -> [String] {
        (String(decoding: message, as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? "").components(separatedBy: "\r\n")
    }

    /// Review focus 2: when the copy to Sent fails, the mail still counts as sent, so no bot sends it twice.
    func testSentStaysSentWhenTheCopyFails() async throws {
        imap.folderList = [MailFolder(name: "Sent", role: .sent)]
        imap.appendError = IMAPError.commandFailed("NO over quota")
        let receipt = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
        XCTAssertEqual(smtp.sent.count, 1)
        XCTAssertFalse(receipt.savedToSent)
    }

    /// Providers that file sent mail themselves get no second copy.
    func testNoCopyWhenTheProviderFilesSentMail() async throws {
        let receipt = try await session(saveSentCopy: false).send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
        XCTAssertTrue(imap.appended.isEmpty)
        XCTAssertEqual(imap.logins, 0)
        XCTAssertFalse(receipt.savedToSent)
    }

    /// A failed send is reported with the server's meaning, and the SMTP connection is still closed.
    func testFailedSendReportsAndCloses() async {
        smtp.sendError = SMTPError.authenticationFailed("535")
        do {
            _ = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .authenticationFailed(host: "smtp.seznam.cz"))
            XCTAssertEqual(smtp.logouts, 1)
        }
    }

    /// When the server stops answering after taking the mail, the error says it may have been sent, and no copy is filed in Sent: only a confirmed send is.
    func testUnknownSendOutcomeFilesNoCopy() async {
        imap.folderList = [MailFolder(name: "Sent", role: .sent)]
        smtp.sendError = SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .connectionLost)
        do {
            _ = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .sendOutcomeUnknown(host: "smtp.seznam.cz"))
            XCTAssertTrue(imap.appended.isEmpty)
            XCTAssertEqual(imap.logins, 0)
            XCTAssertEqual(smtp.logouts, 1)
        }
    }

    /// A cancelled call stays a cancellation on IMAP and SMTP alike, instead of reading as a server refusal.
    func testCancellationPassesThroughUnchanged() async {
        imap.loginError = CancellationError()
        do {
            _ = try await session().list(MessageQuery())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "list: \(error)")
        }
        smtp.sendError = CancellationError()
        do {
            _ = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "send: \(error)")
            XCTAssertEqual(smtp.logouts, 1)
        }
        smtp = FakeSMTP()
        smtp.loginError = CancellationError()
        do {
            try await session().checkSending()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "checkSending: \(error)")
            XCTAssertEqual(smtp.logouts, 1)
        }
    }

    /// Once the mail is out, a cancellation while its copy is filed doesn't turn the send into an error, which would invite a second send.
    func testCancellationWhileFilingTheCopyStillCountsAsSent() async throws {
        imap.folderList = [MailFolder(name: "Sent", role: .sent)]
        imap.appendError = CancellationError()
        let receipt = try await session().send(OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x"))
        XCTAssertEqual(smtp.sent.count, 1)
        XCTAssertFalse(receipt.savedToSent)
    }
}
