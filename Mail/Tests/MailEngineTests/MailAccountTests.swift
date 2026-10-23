import MailEngine
import SwiftMail
import XCTest

final class MailAccountTests: XCTestCase {
    /// Implicit TLS and STARTTLS map to SwiftMail's explicit modes, never to its port-guessing automatic mode.
    func testSecureSettingsMapToExplicitModes() throws {
        XCTAssertEqual(try MailServer(host: "imap.seznam.cz", port: 993, security: .tls).transportSecurity(), .implicitTLS)
        XCTAssertEqual(try MailServer(host: "smtp.seznam.cz", port: 587, security: .startTLS).transportSecurity(), .startTLS)
    }

    /// Plain text is allowed to this Mac only, so a mistyped setting can never send a password unencrypted.
    func testPlainTextIsRefusedForRealHosts() {
        XCTAssertEqual(try MailServer(host: "127.0.0.1", port: 1143, security: .plainText).transportSecurity(), .plainText)
        XCTAssertEqual(try MailServer(host: "localhost", port: 1143, security: .plainText).transportSecurity(), .plainText)
        XCTAssertThrowsError(try MailServer(host: "imap.seznam.cz", port: 143, security: .plainText).transportSecurity()) {
            XCTAssertEqual($0 as? MailEngineError, .insecureServer(host: "imap.seznam.cz"))
        }
    }

    /// Settings survive a save and load unchanged, including the folder overrides.
    func testAccountRoundTripsThroughJSON() throws {
        let account = MailAccount(address: "borek@mail.example.org", displayName: "Bořek", username: "borek@mail.example.org",
            imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
            smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls),
            draftsFolder: "Rozepsan&AOk-", sentFolder: "Odeslan&AOk-", saveSentCopy: true)
        let decoded = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded, account)
    }
}
