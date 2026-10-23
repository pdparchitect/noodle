import MailEngine
import XCTest
@testable import MailCore

final class MailServerLookupTests: XCTestCase {
    /// Answers from memory and remembers every question, in order. Unknown URLs are missing; unknown domains have no MX.
    private final class FakeNetwork: MailLookupNetwork, @unchecked Sendable {
        private let lock = NSLock()
        var files: [String: MailFetch] = [:]
        var otherwise = MailFetch.missing
        var exchangers: [String: [String]] = [:]
        var dnsFails = false
        private var questions: [String] = []
        var asked: [String] { lock.withLock { questions } }
        func fetch(_ url: URL) async -> MailFetch {
            lock.withLock { questions.append(url.absoluteString); return files[url.absoluteString] ?? otherwise }
        }
        func mailExchangers(for domain: String) async -> [String]? {
            lock.withLock { questions.append("MX " + domain); return dnsFails ? nil : exchangers[domain] ?? [] }
        }
    }
    private func config(_ imapHost: String, _ smtpHost: String, auth: String = "password-cleartext") -> MailFetch {
        .data(Data("""
        <clientConfig version="1.1"><emailProvider id="p">
        <incomingServer type="imap"><hostname>\(imapHost)</hostname><port>993</port><socketType>SSL</socketType><authentication>\(auth)</authentication><username>%EMAILADDRESS%</username></incomingServer>
        <outgoingServer type="smtp"><hostname>\(smtpHost)</hostname><port>465</port><socketType>SSL</socketType><authentication>\(auth)</authentication><username>%EMAILADDRESS%</username></outgoingServer>
        </emailProvider></clientConfig>
        """.utf8))
    }
    private let popOnly = MailFetch.data(Data("""
        <clientConfig version="1.1"><emailProvider id="p">
        <incomingServer type="pop3"><hostname>pop.example.org</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.example.org</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
        </emailProvider></clientConfig>
        """.utf8))
    private func direct(_ domain: String) -> [String] {
        ["https://autoconfig.\(domain)/mail/config-v1.1.xml", "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml",
         "https://autoconfig.thunderbird.net/v1.1/\(domain)"]
    }

    /// The domain's own settings win, and Mozilla is never asked about it.
    func testTheDomainsOwnSettingsComeFirst() async {
        let network = FakeNetwork()
        network.files["https://autoconfig.example.org/mail/config-v1.1.xml"] = config("mail.example.org", "mail.example.org")
        let result = await MailServerLookup(network: network).find(address: "anna@example.org")
        guard case .found(let settings, "example.org", nil) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(settings.imap.host, "mail.example.org")
        XCTAssertEqual(network.asked, ["https://autoconfig.example.org/mail/config-v1.1.xml"])
        XCTAssertEqual(result.message, "Found the servers for example.org. Check them, then Save.")
    }

    /// Mozilla's list is asked about the domain only after both of the domain's own places.
    func testMozillasListIsAskedOnlyAfterTheDomain() async {
        let network = FakeNetwork()
        network.files["https://autoconfig.thunderbird.net/v1.1/gmail.com"] = config("imap.gmail.com", "smtp.gmail.com")
        let result = await MailServerLookup(network: network).find(address: "anna@gmail.com")
        guard case .found(let settings, "gmail.com", nil) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(settings.smtp.host, "smtp.gmail.com")
        XCTAssertEqual(network.asked, direct("gmail.com"))
    }

    /// A company domain on a hosted service is found through its best mail server's parent domains, longest first.
    func testACompanyDomainIsFoundThroughItsMailProvider() async {
        let network = FakeNetwork()
        network.exchangers["mail.example.org"] = ["0123456789abcdef.mx2.emailprofi.seznam.cz.", "0123456789abcdef.mx1.emailprofi.seznam.cz"]
        network.files["https://autoconfig.thunderbird.net/v1.1/seznam.cz"] = config("imap.seznam.cz", "smtp.seznam.cz")
        let result = await MailServerLookup(network: network).find(address: "borek@mail.example.org")
        guard case .found(let settings, "mail.example.org", "seznam.cz") = result else { return XCTFail("\(result)") }
        XCTAssertEqual(settings.imap, MailServer(host: "imap.seznam.cz", port: 993, security: .tls))
        XCTAssertEqual(network.asked, direct("mail.example.org") + ["MX mail.example.org",
            "https://autoconfig.thunderbird.net/v1.1/mx2.emailprofi.seznam.cz",
            "https://autoconfig.thunderbird.net/v1.1/emailprofi.seznam.cz",
            "https://autoconfig.thunderbird.net/v1.1/seznam.cz"])
        XCTAssertEqual(result.message, "Found the servers for mail.example.org at seznam.cz. Check them, then Save.")
    }

    /// An OAuth-only provider ends the lookup with a sentence that says why.
    func testOAuthOnlyStopsTheLookup() async {
        let network = FakeNetwork()
        network.files["https://autoconfig.thunderbird.net/v1.1/outlook.com"] = config("outlook.office365.com", "smtp-mail.outlook.com", auth: "OAuth2")
        let result = await MailServerLookup(network: network).find(address: "anna@outlook.com")
        XCTAssertEqual(result, .oauthOnly(domain: "outlook.com"))
        XCTAssertEqual(network.asked, direct("outlook.com"))
        XCTAssertEqual(result.message, "outlook.com only allows signing in through its own web page (OAuth), which Noodle Mail can't do yet.")
    }

    /// Settings without IMAP don't end the lookup; the next source is asked.
    func testUnusableSettingsDoNotStopTheLookup() async {
        let network = FakeNetwork()
        network.files["https://autoconfig.example.org/mail/config-v1.1.xml"] = popOnly
        network.files["https://autoconfig.thunderbird.net/v1.1/example.org"] = config("imap.example.org", "smtp.example.org")
        let result = await MailServerLookup(network: network).find(address: "anna@example.org")
        guard case .found(let settings, _, nil) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(settings.imap.host, "imap.example.org")
    }

    /// No settings anywhere and no connection at all get different sentences.
    func testNothingFoundVersusNoConnection() async {
        let nothing = FakeNetwork()
        let missing = await MailServerLookup(network: nothing).find(address: "anna@example.org")
        XCTAssertEqual(missing, .notFound(domain: "example.org"))
        XCTAssertEqual(missing.message, "No server settings found for example.org. Enter them below; your provider's help pages list them.")
        let offline = FakeNetwork()
        offline.otherwise = .failed; offline.dnsFails = true
        let unreachable = await MailServerLookup(network: offline).find(address: "anna@example.org")
        XCTAssertEqual(unreachable, .unreachable(domain: "example.org"))
        XCTAssertEqual(unreachable.message, "Couldn't look up the servers for example.org. Check the connection, or enter them below.")
    }

    /// Only the lowercased domain is ever sent: never the address, its local part or an @.
    func testOnlyTheDomainIsEverSent() async {
        let network = FakeNetwork()
        network.exchangers["mail.example.org"] = ["mx.example.net"]
        _ = await MailServerLookup(network: network).find(address: " Borek+news@MAIL.example.org ")
        XCTAssertFalse(network.asked.isEmpty)
        for question in network.asked {
            XCTAssertFalse(question.contains("@"), question)
            XCTAssertFalse(question.lowercased().contains("borek"), question)
            XCTAssertFalse(question.contains("MAIL.example"), question)
        }
    }

    /// An address without a usable domain asks nothing and says what to do.
    func testABadAddressAsksNothing() async {
        let network = FakeNetwork()
        for address in ["borek", "borek@", "@mail.example.org", "borek@localhost", "borek@exa mple.com", ""] {
            let result = await MailServerLookup(network: network).find(address: address)
            XCTAssertEqual(result, .invalidAddress, address)
        }
        XCTAssertEqual(network.asked, [])
        XCTAssertEqual(MailServerLookupResult.invalidAddress.message, "Enter the e-mail address first.")
    }
}
