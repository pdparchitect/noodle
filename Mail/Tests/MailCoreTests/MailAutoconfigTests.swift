import MailEngine
import XCTest
@testable import MailCore

final class MailAutoconfigTests: XCTestCase {
    private func xml(_ servers: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <clientConfig version="1.1"><emailProvider id="example">
        <domain>example.org</domain>
        \(servers)
        <documentation url="https://example.org/help"><descr lang="en">Help</descr></documentation>
        </emailProvider></clientConfig>
        """.utf8)
    }
    private func server(_ kind: String, _ type: String, _ host: String, port: String? = nil, socket: String,
                        auth: [String] = ["password-cleartext"], username: String = "%EMAILADDRESS%") -> String {
        let element = kind == "in" ? "incomingServer" : "outgoingServer"
        return "<\(element) type=\"\(type)\"><hostname>\(host)</hostname>" + (port.map { "<port>\($0)</port>" } ?? "")
            + "<socketType>\(socket)</socketType><username>\(username)</username>"
            + auth.map { "<authentication>\($0)</authentication>" }.joined() + "</\(element)>"
    }
    private var seznam: Data {
        xml(server("in", "imap", "imap.seznam.cz", port: "993", socket: "SSL")
            + server("in", "pop3", "pop3.seznam.cz", port: "995", socket: "SSL")
            + server("out", "smtp", "smtp.seznam.cz", port: "465", socket: "SSL"))
    }

    /// A provider's IMAP and SMTP servers are read with their ports and TLS, signing in with the address.
    func testSeznamSettingsAreRead() {
        XCTAssertEqual(MailAutoconfig.parse(seznam, domain: "mail.example.org"), .settings(MailServerSettings(
            imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
            smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls), username: .address)))
    }

    /// Missing ports become the standard ones, and a provider offering OAuth and passwords is used with a password.
    func testMissingPortsUseTheStandardOnes() {
        let data = xml(server("in", "imap", "imap.gmail.com", socket: "SSL", auth: ["OAuth2", "password-cleartext"])
            + server("out", "smtp", "smtp.gmail.com", socket: "SSL", auth: ["OAuth2", "password-cleartext"]))
        XCTAssertEqual(MailAutoconfig.parse(data, domain: "gmail.com"), .settings(MailServerSettings(
            imap: MailServer(host: "imap.gmail.com", port: 993, security: .tls),
            smtp: MailServer(host: "smtp.gmail.com", port: 465, security: .tls), username: .address)))
        let starttls = xml(server("in", "imap", "mail.example.org", socket: "STARTTLS")
            + server("out", "smtp", "mail.example.org", socket: "STARTTLS"))
        XCTAssertEqual(MailAutoconfig.parse(starttls, domain: "example.org"), .settings(MailServerSettings(
            imap: MailServer(host: "mail.example.org", port: 143, security: .startTLS),
            smtp: MailServer(host: "mail.example.org", port: 587, security: .startTLS), username: .address)))
    }

    /// A provider that signs in only with OAuth is recognised as such, not as missing.
    func testOAuthOnlyProviderIsRecognised() {
        let data = xml(server("in", "imap", "outlook.office365.com", port: "993", socket: "SSL", auth: ["OAuth2"])
            + server("out", "smtp", "smtp-mail.outlook.com", port: "587", socket: "STARTTLS", auth: ["OAuth2"]))
        XCTAssertEqual(MailAutoconfig.parse(data, domain: "outlook.com"), .oauthOnly)
    }

    /// Plain-text servers and POP3-only providers are never used.
    func testPlainTextAndPOPOnlyAreNeverUsed() {
        let plain = xml(server("in", "imap", "mail.example.org", port: "143", socket: "plain")
            + server("out", "smtp", "mail.example.org", port: "25", socket: "plain"))
        XCTAssertEqual(MailAutoconfig.parse(plain, domain: "example.org"), .unusable)
        let pop = xml(server("in", "pop3", "pop.example.org", port: "995", socket: "SSL")
            + server("out", "smtp", "smtp.example.org", port: "465", socket: "SSL"))
        XCTAssertEqual(MailAutoconfig.parse(pop, domain: "example.org"), .unusable)
        let mixed = xml(server("in", "imap", "plain.example.org", port: "143", socket: "plain")
            + server("in", "imap", "imap.example.org", port: "993", socket: "SSL")
            + server("out", "smtp", "smtp.example.org", port: "465", socket: "SSL"))
        guard case .settings(let settings) = MailAutoconfig.parse(mixed, domain: "example.org") else { return XCTFail("TLS entry skipped") }
        XCTAssertEqual(settings.imap.host, "imap.example.org")
    }

    /// %EMAILDOMAIN% in a host name and %EMAILLOCALPART% as the username are filled in; other placeholders fall back to the address.
    func testDomainAndLocalPartPlaceholdersAreFilledIn() {
        let data = xml(server("in", "imap", "mail.%EMAILDOMAIN%", port: "993", socket: "SSL", username: "%EMAILLOCALPART%")
            + server("out", "smtp", "mail.%EMAILDOMAIN%", port: "465", socket: "SSL"))
        XCTAssertEqual(MailAutoconfig.parse(data, domain: "example.org"), .settings(MailServerSettings(
            imap: MailServer(host: "mail.example.org", port: 993, security: .tls),
            smtp: MailServer(host: "mail.example.org", port: 465, security: .tls), username: .localPart)))
        let odd = xml(server("in", "imap", "imap.example.org", port: "993", socket: "SSL", username: "%REALNAME%")
            + server("out", "smtp", "smtp.example.org", port: "465", socket: "SSL"))
        guard case .settings(let settings) = MailAutoconfig.parse(odd, domain: "example.org") else { return XCTFail("not read") }
        XCTAssertEqual(settings.username, .address)
    }

    /// Broken XML, broken or number-only host names, unknown host placeholders and impossible ports are refused.
    func testMalformedDataAndHostileHostNamesAreRefused() {
        XCTAssertEqual(MailAutoconfig.parse(Data("not xml <".utf8), domain: "example.org"), .unusable)
        for host in ["imap.example.org/evil", "imap example.org", "localhost", "%EMAILHOST%.example.org", "-bad.example.org", "imap..example.org",
                     "10.0.0.5", "127.1", "0x7f.1", "127.0.0.0x1"] {
            let data = xml(server("in", "imap", host, port: "993", socket: "SSL") + server("out", "smtp", "smtp.example.org", port: "465", socket: "SSL"))
            XCTAssertEqual(MailAutoconfig.parse(data, domain: "example.org"), .unusable, host)
            XCTAssertFalse(MailAutoconfig.isHostName(host), host)
        }
        let port = xml(server("in", "imap", "imap.example.org", port: "70000", socket: "SSL") + server("out", "smtp", "smtp.example.org", port: "465", socket: "SSL"))
        XCTAssertEqual(MailAutoconfig.parse(port, domain: "example.org"), .unusable)
        XCTAssertTrue(MailAutoconfig.isHostName("0123456789abcdef.mx2.emailprofi.seznam.cz"))
        XCTAssertTrue(MailAutoconfig.isHostName("mail.example.xn--p1ai"), "an internationalised top-level domain starts with a letter too")
        XCTAssertFalse(MailAutoconfig.isHostName("cz"))
    }
}
