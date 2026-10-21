import MailBridge
import MailEngine
import XCTest
@testable import MailCore

final class MailRuntimeTests: XCTestCase {
    private final class Sessions: @unchecked Sendable {
        var made: [(account: MailAccount, password: String)] = []
        var next: () -> FakeSession = { FakeSession() }
        var last: FakeSession?
    }
    private var root: URL!
    private var library: MailboxLibrary!
    private var secrets: MemorySecrets!
    private var sessions: Sessions!
    private var runtime: MailRuntime!
    private var mailbox: MailboxRecord!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = MailboxLibrary(root: root)
        mailbox = MailboxRecord(name: "Bořek", account: MailAccount(address: "borek@mail.example.org", username: "borek@mail.example.org",
            imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls), smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls)))
        try library.save(mailbox)
        secrets = MemorySecrets()
        try secrets.setPassword("hunter2-secret", for: mailbox.id)
        sessions = Sessions()
        runtime = makeRuntime(secrets: secrets)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A runtime over the same library, or over `library` when one is given, whose sessions are the fakes in `sessions`.
    private func makeRuntime(secrets: MailSecretStorage, library: MailboxLibrary? = nil) -> MailRuntime {
        let sessions = self.sessions!
        return MailRuntime(library: library ?? self.library, secrets: secrets) { account, password in
            sessions.made.append((account, password))
            let session = sessions.next()
            sessions.last = session
            return session
        }
    }

    private func perform(_ operation: MailOperation, _ change: (inout MailRequest) -> Void = { _ in }) async -> MailResponse {
        var request = MailRequest(operation, mailboxID: operation == .mailboxes ? nil : mailbox.id)
        change(&request)
        return await runtime.perform(request, caller: "com.pdparchitect.noodle.tools.mail")
    }

    /// The mailbox list names each mailbox and its address, never its servers or password.
    func testMailboxesListOnlyNamesAndAddresses() async throws {
        let response = await perform(.mailboxes)
        XCTAssertEqual(response.mailboxes, [RemoteMailbox(id: mailbox.id, name: "Bořek", address: "borek@mail.example.org")])
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(text.contains("imap.seznam.cz"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(sessions.made.isEmpty, "listing mailboxes signs in nowhere")
    }

    /// A mailbox that was removed from Noodle Mail but is still assigned gets one clear sentence.
    func testAnUnknownMailboxIsAnError() async {
        let response = await perform(.folders) { $0.mailboxID = UUID() }
        XCTAssertEqual(response.error, "This mailbox no longer exists in Noodle Mail.")
    }

    /// An unreadable mailbox list fails every request with its own reason, the mailbox list included, so Noodle keeps the list it has saved, and nothing signs in.
    func testAnUnreadableMailboxListFailsEveryRequest() async throws {
        let damaged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: damaged) }
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: damaged.appendingPathComponent("mailboxes.json"))
        let unreadable = MailboxLibrary(root: damaged)
        let failure = try XCTUnwrap(unreadable.failure)
        runtime = makeRuntime(secrets: secrets, library: unreadable)
        for operation in MailOperation.allCases {
            let response = await perform(operation) { $0.uid = 7; $0.part = "2" }
            XCTAssertEqual(response.error, failure, operation.rawValue)
            XCTAssertNil(response.mailboxes, operation.rawValue)
        }
        let other = await perform(.folders) { $0.mailboxID = UUID() }
        XCTAssertEqual(other.error, failure, "any mailbox id gets the same reason")
        XCTAssertTrue(sessions.made.isEmpty)
    }

    /// A malformed request is refused with one sentence before anything signs in.
    func testAMalformedRequestIsRefusedBeforeSigningIn() async {
        let response = await perform(.read)
        XCTAssertEqual(response.error, "Specify the message UID.")
        XCTAssertTrue(sessions.made.isEmpty, "nothing signed in for a request that was refused")
    }

    /// Without a stored password the bot is told who has to act, and no sign-in is attempted.
    func testAMailboxWithoutAPasswordAsksThePerson() async throws {
        try secrets.setPassword(nil, for: mailbox.id)
        let response = await perform(.folders)
        XCTAssertEqual(response.error, "Open Noodle Mail and enter the password for Bořek.")
        XCTAssertTrue(sessions.made.isEmpty)
    }

    /// A Keychain that refuses to be read is reported as itself, not taken for a missing password, and nothing signs in.
    func testAKeychainThatRefusesIsNotTakenForNoPassword() async {
        let locked = makeRuntime(secrets: ThrowingSecrets(failure: MailError("The Keychain refused the mailbox password (-25293).")))
        let response = await locked.perform(MailRequest(.folders, mailboxID: mailbox.id), caller: "com.pdparchitect.noodle.tools.mail")
        XCTAssertEqual(response.error, "The Keychain refused the mailbox password (-25293).")
        XCTAssertTrue(sessions.made.isEmpty)
    }

    /// Folders come with their raw name, a readable name and their role.
    func testFoldersComeWithReadableNames() async {
        sessions.next = { let fake = FakeSession(); fake.folderList = [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Odeslan&AOk-", role: .sent)]; return fake }
        let response = await perform(.folders)
        XCTAssertEqual(response.folders, [MailFolderInfo(name: "INBOX", display: "INBOX", role: "inbox"),
                                          MailFolderInfo(name: "Odeslan&AOk-", display: "Odeslané", role: "sent")])
    }

    /// Every search filter reaches the engine; list defaults to 20 rows of INBOX.
    func testFiltersReachTheEngine() async throws {
        _ = await perform(.search) {
            $0.folder = "Odeslan&AOk-"
            var query = MailQuery(); query.from = "ada"; query.to = "borek"; query.subject = "Invoice"; query.text = "overdue"
            query.since = "2026-10-01"; query.before = "2026-10-02"
            query.unreadOnly = true; query.limit = 5; query.beforeUID = 900
            $0.query = query
        }
        let search = try XCTUnwrap(sessions.last?.queries.last)
        XCTAssertEqual(search.folder, "Odeslan&AOk-")
        XCTAssertEqual(search.from, "ada")
        XCTAssertEqual(search.to, "borek")
        XCTAssertEqual(search.subject, "Invoice")
        XCTAssertEqual(search.text, "overdue")
        XCTAssertEqual(search.since, MailRequest.day("2026-10-01"))
        XCTAssertEqual(search.before, MailRequest.day("2026-10-02"))
        XCTAssertTrue(search.unreadOnly)
        XCTAssertEqual(search.limit, 5)
        XCTAssertEqual(search.beforeUID, 900)
        _ = await perform(.list)
        let list = try XCTUnwrap(sessions.last?.queries.last)
        XCTAssertEqual(list.folder, "INBOX")
        XCTAssertEqual(list.limit, 20)
    }

    /// Rows carry ISO 8601 dates.
    func testRowsCarryISODates() async {
        sessions.next = { let fake = FakeSession(); fake.rows = [MessageRow(uid: 9, date: Date(timeIntervalSince1970: 0), from: "ada", subject: "Hi", seen: false, attachments: 1)]; return fake }
        let response = await perform(.list)
        XCTAssertEqual(response.messages, [MailMessageRow(uid: 9, date: "1970-01-01T00:00:00Z", from: "ada", subject: "Hi", seen: false, attachments: 1)])
    }

    /// A long message is cut at the requested size and says so; UID, folder and markRead reach the engine, and nothing is marked read unless asked.
    func testReadCutsLongTextAndSaysSo() async throws {
        sessions.next = { let fake = FakeSession(); fake.detail = MessageDetail(uid: 7, from: nil, to: [], cc: [], date: nil, subject: nil, messageId: nil,
                                                                                text: String(repeating: "a", count: 50_000), attachments: []); return fake }
        let short = await perform(.read) { $0.uid = 7 }
        XCTAssertEqual(short.message?.text.count, 20_000)
        XCTAssertEqual(short.message?.truncated, true)
        let first = try XCTUnwrap(sessions.last?.reads.first)
        XCTAssertEqual(first.uid, 7)
        XCTAssertEqual(first.folder, "INBOX")
        XCTAssertFalse(first.markRead, "a read marks nothing as read unless asked")
        let full = await perform(.read) { $0.uid = 8; $0.maxCharacters = 100_000; $0.markRead = true; $0.folder = "Archive" }
        XCTAssertEqual(full.message?.text.count, 50_000)
        XCTAssertEqual(full.message?.truncated, false)
        let last = try XCTUnwrap(sessions.last?.reads.last)
        XCTAssertEqual(last.uid, 8)
        XCTAssertEqual(last.folder, "Archive")
        XCTAssertTrue(last.markRead)
    }

    /// How many attachments a read left out reaches the caller beside the ones it lists.
    func testReadPassesOnHowManyAttachmentsWereLeftOut() async throws {
        sessions.next = {
            let fake = FakeSession()
            fake.detail = MessageDetail(uid: 7, from: nil, to: [], cc: [], date: nil, subject: nil, messageId: nil, text: "Hello",
                                        attachments: [AttachmentInfo(part: "2", name: "a.pdf", type: "application/pdf", size: 3)], attachmentsOmitted: 10)
            return fake
        }
        let response = await perform(.read) { $0.uid = 7 }
        XCTAssertEqual(response.message?.attachments, [MailAttachmentInfo(part: "2", name: "a.pdf", type: "application/pdf", size: 3)])
        XCTAssertEqual(response.message?.attachmentsOmitted, 10)
    }

    /// The text limit counts Unicode scalars, so a body that is one character of 50,000 combining marks is cut at the limit, and a text of exactly the limit is not.
    func testTheTextLimitCountsUnicodeScalarsNotCharacters() async throws {
        let fake = FakeSession()
        sessions.next = { fake }
        // "a" and combining acute accents (two bytes each) make one character of as many scalars as asked.
        func body(scalars: Int) -> String { "a" + String(repeating: "\u{0301}", count: scalars - 1) }
        func read(_ text: String) async -> MailMessage? {
            fake.detail = MessageDetail(uid: 7, from: nil, to: [], cc: [], date: nil, subject: nil, messageId: nil, text: text, attachments: [])
            return await perform(.read) { $0.uid = 7 }.message
        }
        let hostile = body(scalars: 50_001)
        XCTAssertEqual(hostile.count, 1, "the body is one character, so counting characters can never reach the limit")
        let cutMessage = await read(hostile)
        let cut = try XCTUnwrap(cutMessage)
        XCTAssertTrue(cut.truncated)
        XCTAssertLessThanOrEqual(cut.text.unicodeScalars.count, 20_000)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, 80_000, "no scalar takes more than 4 bytes")
        XCTAssertTrue(cut.text.unicodeScalars.elementsEqual(hostile.unicodeScalars.prefix(20_000)), "the text is the body's first 20,000 scalars")
        let atLimit = body(scalars: 20_000)
        let wholeMessage = await read(atLimit)
        let whole = try XCTUnwrap(wholeMessage)
        XCTAssertFalse(whole.truncated, "a text of exactly the limit is not cut")
        XCTAssertTrue(whole.text.unicodeScalars.elementsEqual(atLimit.unicodeScalars))
        let overMessage = await read(body(scalars: 20_001))
        let over = try XCTUnwrap(overMessage)
        XCTAssertTrue(over.truncated, "one scalar over the limit is cut")
        XCTAssertEqual(over.text.unicodeScalars.count, 20_000)
    }

    /// Attachments over 20 MiB are refused with a sentence; one at the limit passes.
    func testLargeAttachmentsAreRefused() async {
        sessions.next = { let fake = FakeSession(); fake.attachmentData = Data(count: MailLimits.attachmentBytes + 1); return fake }
        let large = await perform(.attachment) { $0.uid = 7; $0.part = "2" }
        XCTAssertEqual(large.error, "This attachment is larger than 20 MB. Open it in a mail app instead.")
        sessions.last?.attachmentData = Data(count: MailLimits.attachmentBytes)
        let fits = await perform(.attachment) { $0.uid = 7; $0.part = "2" }
        XCTAssertEqual(fits.attachment?.data.count, MailLimits.attachmentBytes)
    }

    /// An attachment request reaches the engine with its UID, part and folder, INBOX unless one is given, and the bytes come back.
    func testAnAttachmentRequestReachesTheEngine() async throws {
        let response = await perform(.attachment) { $0.uid = 7; $0.part = "2.1"; $0.folder = "Archive" }
        XCTAssertEqual(response.attachment?.data, Data("PDF".utf8))
        _ = await perform(.attachment) { $0.uid = 8; $0.part = "3" }
        let asked = try XCTUnwrap(sessions.last?.attachments)
        XCTAssertEqual(asked.count, 2)
        let one = try XCTUnwrap(asked.first), two = try XCTUnwrap(asked.last)
        XCTAssertEqual(one.uid, 7)
        XCTAssertEqual(one.part, "2.1")
        XCTAssertEqual(one.folder, "Archive")
        XCTAssertEqual(two.uid, 8)
        XCTAssertEqual(two.part, "3")
        XCTAssertEqual(two.folder, "INBOX")
    }

    /// Errors never carry the password: engine errors keep their own sentence, anything else becomes a generic one.
    func testErrorsNeverCarryThePassword() async {
        sessions.next = { let fake = FakeSession(); fake.failure = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "LOGIN hunter2-secret failed"]); return fake }
        let foreign = await perform(.folders)
        XCTAssertFalse(foreign.error?.contains("hunter2") ?? true)
        sessions.next = { let fake = FakeSession(); fake.failure = MailEngineError.authenticationFailed(host: "imap.seznam.cz"); return fake }
        let engine = await perform(.folders)
        XCTAssertTrue(engine.error?.contains("imap.seznam.cz refused the sign-in") == true, engine.error ?? "")
    }

    /// One session serves many calls with the stored password; a failure, a settings change or forget starts a new one.
    func testSessionsAreReusedUntilSomethingChanges() async throws {
        _ = await perform(.folders); _ = await perform(.list)
        XCTAssertEqual(sessions.made.count, 1)
        XCTAssertEqual(sessions.made.first?.password, "hunter2-secret")
        sessions.last?.failure = MailEngineError.timedOut(host: "imap.seznam.cz")
        _ = await perform(.folders)
        _ = await perform(.folders)
        XCTAssertEqual(sessions.made.count, 2, "the failed session was replaced")
        var moved = mailbox!; moved.account.imap.host = "imap2.seznam.cz"
        try library.save(moved)
        _ = await perform(.folders)
        XCTAssertEqual(sessions.made.count, 3, "new settings sign in again")
        await runtime.forget(mailbox.id)
        _ = await perform(.folders)
        XCTAssertEqual(sessions.made.count, 4, "forget drops the session, as after a password change")
    }

    /// A message that is not there is the caller's mistake, not the connection's: the next request reuses the same session, and the caller reads the reason.
    func testANotFoundErrorKeepsTheConnection() async throws {
        _ = await perform(.folders)
        let first = try XCTUnwrap(sessions.last)
        first.failure = MailEngineError.messageNotFound(uid: 9)
        let missing = await perform(.read) { $0.uid = 9 }
        XCTAssertEqual(missing.error, "Message 9 is not in this folder.")
        first.failure = nil
        let found = await perform(.read) { $0.uid = 7 }
        XCTAssertNil(found.error)
        XCTAssertEqual(found.message?.uid, 7)
        XCTAssertEqual(sessions.made.count, 1, "the same sign-in served both reads")
        XCTAssertFalse(first.closed)
    }

    /// A timeout may leave the connection stale, so the next request signs in again and the old session is signed out.
    func testATimeoutDropsTheConnection() async throws {
        _ = await perform(.folders)
        let first = try XCTUnwrap(sessions.last)
        let signedOut = expectation(description: "the old session is signed out")
        first.onClose = { signedOut.fulfill() }
        first.failure = MailEngineError.timedOut(host: "imap.seznam.cz")
        let timedOut = await perform(.read) { $0.uid = 7 }
        XCTAssertEqual(timedOut.error, "imap.seznam.cz did not answer in time.")
        let again = await perform(.read) { $0.uid = 7 }
        XCTAssertNil(again.error)
        XCTAssertEqual(sessions.made.count, 2, "the next request signed in again")
        XCTAssertFalse(try XCTUnwrap(sessions.last) === first)
        await fulfillment(of: [signedOut], timeout: 5)
    }

    /// Shutting down signs every open session out and leaves none to reuse.
    func testShutdownSignsEverySessionOut() async throws {
        let second = MailboxRecord(name: "Klára", account: mailbox.account)
        try library.save(second)
        try secrets.setPassword("klara-secret", for: second.id)
        _ = await perform(.folders)
        let borek = try XCTUnwrap(sessions.last)
        _ = await perform(.folders) { $0.mailboxID = second.id }
        let klara = try XCTUnwrap(sessions.last)
        XCTAssertFalse(borek === klara)
        XCTAssertFalse(borek.closed || klara.closed, "sessions stay open until shutdown")
        await runtime.shutdown()
        XCTAssertTrue(borek.closed)
        XCTAssertTrue(klara.closed)
        _ = await perform(.folders)
        XCTAssertEqual(sessions.made.count, 3, "after shutdown the next call signs in again")
    }
}
