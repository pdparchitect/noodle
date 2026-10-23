import MailBridge
import MailEngine
import XCTest
@testable import MailCore

final class MailboxDraftTests: XCTestCase {
    private let seznamSettings = MailServerSettings(imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
                                                    smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls), username: .address)
    private func seznam() -> MailboxDraft {
        var draft = MailboxDraft()
        draft.name = "Bořek"; draft.address = " borek@mail.example.org "
        draft.apply(seznamSettings)
        return draft
    }
    private func problem(_ change: (inout MailboxDraft) -> Void) -> String? {
        var draft = seznam(); change(&draft)
        do { _ = try draft.record(id: UUID()); return nil } catch { return (error as? MailError)?.message ?? "\(error)" }
    }

    /// Found settings with an address make a complete mailbox that signs in with the address, or with the username when one is typed.
    func testFoundSettingsMakeAValidMailbox() throws {
        let id = UUID()
        let record = try seznam().record(id: id)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.account.address, "borek@mail.example.org")
        XCTAssertEqual(record.account.username, "borek@mail.example.org")
        XCTAssertEqual(record.account.imap, MailServer(host: "imap.seznam.cz", port: 993, security: .tls))
        XCTAssertEqual(record.account.smtp, MailServer(host: "smtp.seznam.cz", port: 465, security: .tls))
        var named = seznam(); named.username = " borek.login "
        XCTAssertEqual(try named.record(id: UUID()).account.username, "borek.login")
    }

    /// Each mistake is named in words a person can act on.
    func testProblemsAreNamedPlainly() {
        XCTAssertEqual(problem { $0.name = " " }, "Give the mailbox a name of up to 100 characters.")
        XCTAssertEqual(problem { $0.address = "borek" }, "Enter the mailbox's e-mail address.")
        XCTAssertEqual(problem { $0.username = "a\nb" }, "Enter the username on one line.")
        XCTAssertEqual(problem { $0.imapHost = "imap seznam.cz" }, "Enter the IMAP server's host name, such as imap.example.com.")
        XCTAssertEqual(problem { $0.smtpHost = "" }, "Enter the SMTP server's host name, such as smtp.example.com.")
        XCTAssertEqual(problem { $0.smtpPort = 0 }, "The SMTP port must be 1 to 65535.")
        XCTAssertTrue(problem { $0.imapSecurity = .plainText }?.contains("plain text") == true, "plain text to a real host is refused")
    }

    /// Editing keeps what the form doesn't show, and a username equal to the address shows as empty.
    func testEditingKeepsHiddenSettings() throws {
        var existing = try seznam().record(id: UUID())
        existing.account.sentFolder = "Odeslan&AOk-"; existing.account.saveSentCopy = false
        existing.account.displayName = "Bořek F."; existing.account.draftsFolder = "Rozepsan&AOk-"
        var draft = MailboxDraft(existing)
        XCTAssertEqual(draft.username, "")
        draft.name = "Bořek (team)"
        let edited = try draft.record(id: existing.id, keeping: existing)
        XCTAssertEqual(edited.name, "Bořek (team)")
        XCTAssertEqual(edited.account.sentFolder, "Odeslan&AOk-")
        XCTAssertFalse(edited.account.saveSentCopy)
        XCTAssertEqual(edited.account.displayName, "Bořek F.")
        XCTAssertEqual(edited.account.draftsFolder, "Rozepsan&AOk-")
    }

    /// Found settings replace the servers, and the username when it is empty, the address or its local part; the name and address stay as typed.
    func testFoundSettingsReplaceOnlyServersAndUsername() {
        var draft = MailboxDraft()
        draft.name = "Klára's invoices"; draft.address = "klara.f@example.org"; draft.username = " Klara.F@Example.org "
        draft.imapHost = "old.example.org"; draft.imapPort = 1993; draft.smtpSecurity = .startTLS
        draft.apply(MailServerSettings(imap: MailServer(host: "mail.example.org", port: 143, security: .startTLS),
                                       smtp: MailServer(host: "mail.example.org", port: 465, security: .tls), username: .localPart))
        XCTAssertEqual(draft.name, "Klára's invoices")
        XCTAssertEqual(draft.address, "klara.f@example.org")
        XCTAssertEqual(draft.username, "klara.f", "the address, in any case or spacing, is a value Find Servers may replace")
        XCTAssertEqual([draft.imapHost, "\(draft.imapPort)", draft.imapSecurity.rawValue], ["mail.example.org", "143", "startTLS"])
        XCTAssertEqual([draft.smtpHost, "\(draft.smtpPort)", draft.smtpSecurity.rawValue], ["mail.example.org", "465", "tls"])
        draft.username = " KLARA.f "
        draft.apply(MailServerSettings(imap: draft.currentIMAP(), smtp: draft.currentSMTP(), username: .address))
        XCTAssertEqual(draft.username, "", "the local part, in any case or spacing, is a value Find Servers may replace")
        draft.apply(MailServerSettings(imap: draft.currentIMAP(), smtp: draft.currentSMTP(), username: .fixed("shared-login")))
        XCTAssertEqual(draft.username, "shared-login", "an empty username takes the provider's fixed one")
    }

    /// A username the person typed stays when Find Servers fills in the servers, whatever rule the provider's settings give.
    func testATypedUsernameSurvivesFindServers() {
        for rule in [MailUsername.address, .localPart, .fixed("shared-login")] {
            var draft = MailboxDraft()
            draft.address = "klara.f@example.org"; draft.username = "klara.login"
            draft.apply(MailServerSettings(imap: MailServer(host: "mail.example.org", port: 143, security: .startTLS),
                                           smtp: MailServer(host: "mail.example.org", port: 465, security: .tls), username: rule))
            XCTAssertEqual(draft.username, "klara.login", "\(rule)")
            XCTAssertEqual(draft.imapHost, "mail.example.org", "\(rule)")
            XCTAssertEqual(draft.smtpHost, "mail.example.org", "\(rule)")
        }
    }

    /// Correcting a mistyped address and running Find Servers again gives the corrected address's username, not the old one.
    func testACorrectedAddressGetsItsOwnUsername() {
        var draft = MailboxDraft()
        draft.address = "klra@x.org"
        draft.apply(settings(.localPart))
        XCTAssertEqual(draft.username, "klra")
        draft.address = "klara@x.org"
        draft.apply(settings(.localPart))
        XCTAssertEqual(draft.username, "klara")
    }

    /// A username Find Servers made from the address's local part follows a corrected address without another Find Servers;
    /// a provider's fixed login and a username the person typed stay as they are.
    func testAnAutoFilledLocalPartFollowsACorrectedAddress() {
        var draft = MailboxDraft()
        draft.address = "klra@x.org"
        draft.apply(settings(.localPart))
        XCTAssertEqual(draft.username, "klra")
        draft.address = "klara@x.org"
        XCTAssertEqual(draft.username, "klara", "the auto-filled local part follows the corrected address")
        draft.username = "boss"
        draft.address = "klarka@x.org"
        XCTAssertEqual(draft.username, "boss", "a typed username stays")
        var fixed = MailboxDraft()
        fixed.address = "klra@x.org"
        fixed.apply(settings(.fixed("login-a")))
        fixed.address = "klara@x.org"
        XCTAssertEqual(fixed.username, "login-a", "a fixed login doesn't come from the address")
    }

    /// A fixed login a provider's settings gave earlier is replaced by the one the next lookup gives.
    func testAFixedLoginFromAnEarlierLookupIsReplaced() {
        var draft = MailboxDraft()
        draft.address = "klara@x.org"
        draft.apply(settings(.fixed("login-a")))
        XCTAssertEqual(draft.username, "login-a")
        draft.apply(settings(.fixed("login-b")))
        XCTAssertEqual(draft.username, "login-b")
    }

    /// A username the person typed over an auto-filled one stays through the next Find Servers.
    func testATypedUsernameStillSurvives() {
        var draft = MailboxDraft()
        draft.address = "klra@x.org"
        draft.apply(settings(.localPart))
        draft.username = "boss"
        draft.apply(settings(.localPart))
        XCTAssertEqual(draft.username, "boss")
    }

    /// Only a found result changes the form; every result returns its sentence.
    func testOnlyAFoundResultChangesTheForm() {
        var draft = MailboxDraft()
        draft.address = "anna@outlook.com"; draft.imapHost = "typed.example.org"
        let before = draft
        for result in [MailServerLookupResult.oauthOnly(domain: "outlook.com"), .notFound(domain: "outlook.com"),
                       .unreachable(domain: "outlook.com"), .invalidAddress] {
            XCTAssertEqual(draft.apply(result), result.message)
            XCTAssertEqual(draft, before)
        }
        XCTAssertEqual(draft.apply(.found(seznamSettings, domain: "mail.example.org", provider: "seznam.cz")),
                       "Found the servers for mail.example.org at seznam.cz. Check them, then Save.")
        XCTAssertEqual(draft.imapHost, "imap.seznam.cz")
    }

    /// A result for a domain the person has since changed is dropped without touching the form.
    func testAResultForAChangedDomainIsDropped() {
        var draft = MailboxDraft()
        draft.address = "anna@gmail.com"; draft.imapHost = "typed.example.org"
        let before = draft
        XCTAssertNil(draft.apply(.found(seznamSettings, domain: "mail.example.org", provider: "seznam.cz"), lookedUp: "borek@mail.example.org"))
        XCTAssertEqual(draft, before)
    }

    /// A result still applies when only the local part, case or spacing of the address changed.
    func testAResultForTheSameDomainStillApplies() {
        var draft = MailboxDraft()
        draft.address = " Borek.F@MAIL.example.org "
        XCTAssertEqual(draft.apply(.found(seznamSettings, domain: "mail.example.org", provider: "seznam.cz"), lookedUp: "borek@mail.example.org"),
                       "Found the servers for mail.example.org at seznam.cz. Check them, then Save.")
        XCTAssertEqual(draft.imapHost, "imap.seznam.cz")
    }
}

/// Settings for mail.example.org with the given username rule.
private func settings(_ username: MailUsername) -> MailServerSettings {
    MailServerSettings(imap: MailServer(host: "mail.example.org", port: 143, security: .startTLS),
                       smtp: MailServer(host: "mail.example.org", port: 465, security: .tls), username: username)
}

private extension MailboxDraft {
    /// The form's current servers, to re-apply them with another username rule.
    func currentIMAP() -> MailServer { MailServer(host: imapHost, port: imapPort, security: imapSecurity) }
    func currentSMTP() -> MailServer { MailServer(host: smtpHost, port: smtpPort, security: smtpSecurity) }
}
