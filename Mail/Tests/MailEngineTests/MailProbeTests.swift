@testable import MailEngine
@testable import mail_probe
import XCTest

final class MailProbeTests: XCTestCase {
    private func session(_ imap: FakeIMAP) -> MailSession {
        let account = MailAccount(address: "borek@mail.example.org", username: "borek@mail.example.org",
                                  imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
                                  smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls))
        return MailSession(account: account, password: "secret", imap: imap, smtp: FakeSMTP())
    }

    /// The probe's read check reports only how long the text is, whether there is any, and how many attachments there are, never the text, subject or file names, and leaves the mail unread.
    func testReadCheckShowsNoContent() async throws {
        let imap = FakeIMAP()
        imap.records = [HeaderRecord.sample(uid: 7, subject: "Tajná smlouva", parts: [
            PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 24),
            PartRecord(section: "2", contentType: "application/pdf", charset: nil, disposition: "attachment", filename: "smlouva-podpis.pdf", size: 900),
        ])]
        imap.partBytes["7:1"] = Data("Heslo k trezoru je 1234.".utf8)
        let check = await ReadCheck.of(uid: 7, in: session(imap))
        XCTAssertEqual(try MailJSON.encode(check), #"{"attachments":1,"hasText":true,"textLength":24}"#)
        XCTAssertEqual(imap.seen, [])
    }

    /// A read that fails shows up in the report as its error text instead of stopping the probe.
    func testFailedReadIsReported() async throws {
        let check = await ReadCheck.of(uid: 404, in: session(FakeIMAP()))
        XCTAssertEqual(try MailJSON.encode(check), #"{"error":"Message 404 is not in this folder."}"#)
    }
}
