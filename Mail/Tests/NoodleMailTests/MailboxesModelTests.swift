import MailBridge
import MailCore
import MailEngine
import XCTest
@testable import NoodleMail

@MainActor final class MailboxesModelTests: XCTestCase {
    /// Passwords in memory, so tests never touch the person's Keychain.
    private final class Secrets: MailSecretStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: String] = [:]
        func password(for mailbox: UUID) throws -> String? { lock.withLock { values[mailbox] } }
        func hasPassword(for mailbox: UUID) -> Bool { lock.withLock { values[mailbox] != nil } }
        func setPassword(_ password: String?, for mailbox: UUID) throws { lock.withLock { values[mailbox] = password.flatMap { $0.isEmpty ? nil : $0 } } }
    }
    /// A signed-in mailbox that answers from memory. It keeps the password it was opened with and signals when it is closed.
    private final class FakeSession: MailboxSession, @unchecked Sendable {
        let password: String
        let closed = XCTestExpectation(description: "The session was closed.")
        init(password: String) { self.password = password }
        func folders() async throws -> [MailFolder] { [MailFolder(name: "INBOX", role: nil)] }
        func list(_ query: MessageQuery) async throws -> [MessageRow] { [] }
        func read(uid: Int, folder: String, markRead: Bool) async throws -> MessageDetail { throw MailError("Not used.") }
        func attachment(uid: Int, part: String, folder: String) async throws -> Data { throw MailError("Not used.") }
        func close() async { closed.fulfill() }
    }
    /// The sessions the runtime signed in, in order: one entry per call to its session factory.
    private final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeSession] = []
        var all: [FakeSession] { lock.withLock { made } }
        func open(_ password: String) -> FakeSession {
            let session = FakeSession(password: password)
            lock.withLock { made.append(session) }
            return session
        }
    }
    private struct Fixture { let root: URL; let library: MailboxLibrary; let secrets: Secrets; let sessions: Sessions; let model: MailboxesModel }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MailboxLibrary(root: root), secrets = Secrets(), sessions = Sessions()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = MailRuntime(library: library, secrets: secrets) { _, password in sessions.open(password) }
        return Fixture(root: root, library: library, secrets: secrets, sessions: sessions,
                       model: MailboxesModel(library: library, secrets: secrets, runtime: runtime))
    }
    private func draft() -> MailboxDraft {
        var draft = MailboxDraft()
        draft.name = "Klára"; draft.address = "klara@mail.example.org"
        draft.apply(MailServerSettings(imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
                                       smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls), username: .address))
        return draft
    }
    /// What a bot's first call does: the runtime signs in to the mailbox and lists its folders.
    private func signIn(_ f: Fixture, _ id: UUID) async -> MailResponse {
        await f.model.runtime.perform(MailRequest(.folders, mailboxID: id), caller: "test")
    }

    /// A new mailbox is listed and its password goes to the secret store only, never into the list file.
    func testSavingKeepsThePasswordOutOfTheList() async throws {
        let f = fixture()
        let saved = try await f.model.save(draft(), password: "pw-123456", id: nil)
        XCTAssertEqual(f.model.mailboxes.map(\.name), ["Klára"])
        XCTAssertEqual(try f.secrets.password(for: saved.id), "pw-123456")
        XCTAssertFalse(try String(contentsOf: f.root.appendingPathComponent("mailboxes.json"), encoding: .utf8).contains("pw-123456"))
    }

    /// A new mailbox can't be saved without a password.
    func testANewMailboxNeedsAPassword() async {
        let f = fixture()
        do { _ = try await f.model.save(draft(), password: "", id: nil); XCTFail("Expected a refusal.") }
        catch { XCTAssertEqual((error as? MailError)?.message, "Enter the mailbox password (an app password if two-factor login is on).") }
        XCTAssertTrue(f.model.mailboxes.isEmpty)
    }

    /// Editing with an empty password field keeps the stored password, and the settings the form doesn't show.
    func testAnEmptyPasswordFieldKeepsTheStoredOne() async throws {
        let f = fixture()
        let saved = try await f.model.save(draft(), password: "pw-123456", id: nil)
        var stored = saved; stored.account.sentFolder = "Odeslan&AOk-"   // a setting the form has no field for
        try f.library.save(stored)
        var renamed = MailboxDraft(saved); renamed.name = "Klára (invoices)"
        _ = try await f.model.save(renamed, password: "", id: saved.id)
        XCTAssertEqual(f.model.mailboxes.map(\.name), ["Klára (invoices)"])
        XCTAssertEqual(f.model.mailboxes.first?.account.sentFolder, "Odeslan&AOk-")
        XCTAssertEqual(try f.secrets.password(for: saved.id), "pw-123456")
    }

    /// Saving a new password makes the next call sign in again with it, instead of reusing the old session.
    func testSavingANewPasswordSignsInAgainWithIt() async throws {
        let f = fixture()
        let saved = try await f.model.save(draft(), password: "pw-123456", id: nil)
        let first = await signIn(f, saved.id)
        XCTAssertNil(first.error)
        XCTAssertEqual(f.sessions.all.map(\.password), ["pw-123456"])
        _ = try await f.model.save(MailboxDraft(saved), password: "pw-654321", id: saved.id)
        let second = await signIn(f, saved.id)
        XCTAssertNil(second.error)
        XCTAssertEqual(f.sessions.all.map(\.password), ["pw-123456", "pw-654321"])
    }

    /// Removing a mailbox deletes its password and signs it out; a bot that still asks for it is told it is gone.
    func testRemovingAMailboxDeletesItsPassword() async throws {
        let f = fixture()
        let saved = try await f.model.save(draft(), password: "pw-123456", id: nil)
        let signedIn = await signIn(f, saved.id)
        XCTAssertNil(signedIn.error)
        let session = try XCTUnwrap(f.sessions.all.first)
        try await f.model.remove(saved.id)
        XCTAssertTrue(f.model.mailboxes.isEmpty)
        XCTAssertFalse(f.secrets.hasPassword(for: saved.id))
        let gone = await signIn(f, saved.id)
        XCTAssertEqual(gone.error, "This mailbox no longer exists in Noodle Mail.")
        await fulfillment(of: [session.closed], timeout: 5)
    }

    /// The settings window looks addresses up through the lookup it was given.
    func testFindServersUsesTheGivenLookup() async {
        final class OneFile: MailLookupNetwork, @unchecked Sendable {
            func fetch(_ url: URL) async -> MailFetch {
                guard url.absoluteString == "https://autoconfig.example.org/mail/config-v1.1.xml" else { return .missing }
                return .data(Data("""
                <clientConfig version="1.1"><emailProvider id="p">
                <incomingServer type="imap"><hostname>mail.example.org</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
                <outgoingServer type="smtp"><hostname>mail.example.org</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
                </emailProvider></clientConfig>
                """.utf8))
            }
            func mailExchangers(for domain: String) async -> [String]? { [] }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = MailboxLibrary(root: root), secrets = Secrets()
        let model = MailboxesModel(library: library, secrets: secrets,
                                   runtime: MailRuntime(library: library, secrets: secrets) { _, password in FakeSession(password: password) },
                                   lookup: MailServerLookup(network: OneFile()))
        let result = await model.findServers(for: "anna@example.org")
        guard case .found(let settings, "example.org", nil) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(settings.smtp.host, "mail.example.org")
    }
}
