import MailEngine
import XCTest
@testable import MailCore

final class MailLookupLiveNetworkTests: XCTestCase {
    private func rdata(_ preference: UInt16, _ labels: [String]) -> [UInt8] {
        [UInt8(preference >> 8), UInt8(preference & 0xFF)] + labels.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }
    private func exchanger(_ bytes: [UInt8]) -> (preference: Int, host: String)? {
        bytes.withUnsafeBytes { MailLookupLiveNetwork.exchanger($0) }
    }

    /// An MX record's data gives its preference and its host, lowercased.
    func testAnMXRecordIsRead() throws {
        let record = try XCTUnwrap(exchanger(rdata(10, ["0123456789abcdef", "MX2", "emailprofi", "seznam", "cz"])))
        XCTAssertEqual(record.preference, 10)
        XCTAssertEqual(record.host, "0123456789abcdef.mx2.emailprofi.seznam.cz")
    }

    /// Truncated data, compression pointers and non-host labels are refused rather than misread.
    func testBrokenMXDataIsRefused() {
        XCTAssertNil(exchanger([0, 10]))
        XCTAssertNil(exchanger(Array(rdata(10, ["mx", "example", "org"]).dropLast())))
        XCTAssertNil(exchanger([0, 10, 0xC0, 0x0C]))
        XCTAssertNil(exchanger(rdata(10, ["mx example", "org"])))
    }

    /// Redirects are followed only to HTTPS.
    func testRedirectsStayOnHTTPS() {
        XCTAssertTrue(MailLookupLiveNetwork.allowsRedirect(to: URL(string: "https://autoconfig.example.org/x.xml")))
        XCTAssertFalse(MailLookupLiveNetwork.allowsRedirect(to: URL(string: "http://autoconfig.example.org/x.xml")))
        XCTAssertFalse(MailLookupLiveNetwork.allowsRedirect(to: URL(string: "file:///etc/passwd")))
        XCTAssertFalse(MailLookupLiveNetwork.allowsRedirect(to: nil))
    }

    /// Asks the real network, only when MAIL_LIVE_LOOKUP=1: Seznam and Gmail are both found.
    func testLiveLookupFindsRealProviders() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAIL_LIVE_LOOKUP"] == "1", "Set MAIL_LIVE_LOOKUP=1 to ask the real network.")
        let seznam = await MailServerLookup().find(address: "someone@seznam.cz")
        guard case .found(let settings, "seznam.cz", _) = seznam else { return XCTFail("\(seznam)") }
        XCTAssertEqual(settings.imap, MailServer(host: "imap.seznam.cz", port: 993, security: .tls))
        let gmail = await MailServerLookup().find(address: "someone@gmail.com")
        guard case .found(let google, "gmail.com", _) = gmail else { return XCTFail("\(gmail)") }
        XCTAssertEqual(google.imap.host, "imap.gmail.com")
    }
}
