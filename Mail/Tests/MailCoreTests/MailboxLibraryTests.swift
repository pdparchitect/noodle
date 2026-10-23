import MailBridge
import MailEngine
import XCTest
@testable import MailCore

final class MailboxLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("NoodleMail")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func record(_ name: String) -> MailboxRecord {
        MailboxRecord(name: name, account: MailAccount(address: "\(name.lowercased())@mail.example.org", username: "\(name.lowercased())@mail.example.org",
            imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls), smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls)))
    }

    /// Saved mailboxes come back after a restart, in a folder and file only this user can open.
    func testMailboxesSurviveARestartPrivately() throws {
        let library = MailboxLibrary(root: root)
        let klara = record("Klara"), borek = record("Borek")
        try library.save(klara); try library.save(borek)
        XCTAssertEqual(MailboxLibrary(root: root).mailboxes(), [klara, borek])
        let file = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mailboxes.json").path)
        let folder = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(folder[.posixPermissions] as? Int, 0o700)
    }

    /// Saving an existing id replaces that mailbox; removing deletes it.
    func testSaveReplacesByIDAndRemoveDeletes() throws {
        let library = MailboxLibrary(root: root)
        var klara = record("Klara")
        try library.save(klara)
        klara.name = "Klára (invoices)"
        try library.save(klara)
        XCTAssertEqual(library.mailboxes().map(\.name), ["Klára (invoices)"])
        try library.remove(klara.id)
        XCTAssertEqual(library.mailboxes(), [])
    }

    /// A list that can't be read is reported and never overwritten, so a bad update loses nothing.
    func testAnUnreadableListIsReportedAndKept() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("mailboxes.json")
        try Data("not json".utf8).write(to: file)
        let library = MailboxLibrary(root: root)
        XCTAssertNotNil(library.failure)
        XCTAssertEqual(library.mailboxes(), [])
        XCTAssertThrowsError(try library.save(record("Klara")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    /// A list that can't be read says what went wrong and then what to try, by the cause: a list from a newer version asks for an
    /// update, and any other failure to quit and reopen.
    func testAnUnreadableListSaysWhatToDo() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("mailboxes.json")
        try Data(#"{"version": 2, "mailboxes": []}"#.utf8).write(to: file)
        XCTAssertEqual(MailboxLibrary(root: root).failure,
                       "Noodle Mail could not read its mailbox list, so it was left unchanged. It comes from a newer Noodle Mail. "
                       + "Update Noodle Mail.")
        try Data("not json".utf8).write(to: file)
        let damaged = try XCTUnwrap(MailboxLibrary(root: root).failure)
        XCTAssertTrue(damaged.hasPrefix("Noodle Mail could not read its mailbox list, so it was left unchanged. "), damaged)
        XCTAssertTrue(damaged.hasSuffix(" Quit and reopen Noodle Mail. If it stays, check the mailbox list file's permissions."), damaged)
    }

    /// The list file has no place for a password, and what Noodle sees of a mailbox is its id, name and address.
    func testTheListNeverHoldsServersForNoodleOrAPassword() throws {
        let library = MailboxLibrary(root: root)
        let klara = record("Klara")
        try library.save(klara)
        let text = try String(contentsOf: root.appendingPathComponent("mailboxes.json"), encoding: .utf8)
        XCTAssertFalse(text.lowercased().contains("password"))
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(klara.remote)) as? [String: Any])
        XCTAssertEqual(Set(remote.keys), ["id", "name", "address"])
    }

    /// The list holds at most 100 mailboxes.
    func testTheListIsBounded() throws {
        let library = MailboxLibrary(root: root)
        for index in 0..<MailboxLibrary.limit { try library.save(record("M\(index)")) }
        XCTAssertThrowsError(try library.save(record("One too many")))
    }
}
