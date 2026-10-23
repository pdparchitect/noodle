@testable import MailEngine
import SwiftMail
import XCTest

final class MailClientsTests: XCTestCase {
    private func role(_ name: String, _ attributes: Mailbox.Info.Attributes = [], delimiter: String? = "/", marks: Bool) -> FolderRole? {
        FolderRole(attributes: attributes, name: name, delimiter: delimiter, serverMarksRoles: marks)
    }

    /// Without SPECIAL-USE only a well-known English folder name gives a role, matched whole and in any case, so "Presentations" is never taken for Sent.
    func testWithoutSpecialUseOnlyWellKnownNamesGiveARole() {
        let known: [(String, FolderRole)] = [
            ("INBOX", .inbox), ("Drafts", .drafts), ("Sent", .sent), ("Sent Items", .sent), ("Sent Messages", .sent),
            ("Trash", .trash), ("Deleted Items", .trash), ("Junk", .junk), ("Spam", .junk), ("Archive", .archive),
            ("sent items", .sent), ("DRAFTS", .drafts), ("Inbox", .inbox),
        ]
        for (name, expected) in known {
            XCTAssertEqual(role(name, marks: false), expected, name)
        }
        for name in ["Presentations", "Consent", "Unsent", "Contract drafts", "Sent Mail", "Rozepsan&AOk-", "Odeslan&AOk-", "Faktury"] {
            XCTAssertNil(role(name, marks: false), name)
        }
    }

    /// The name compared is the last part of the folder's path, split at the server's own delimiter.
    func testTheNameIsTheLastPathComponent() {
        XCTAssertEqual(role("INBOX.Sent", delimiter: ".", marks: false), .sent)
        XCTAssertEqual(role("INBOX/Drafts", delimiter: "/", marks: false), .drafts)
        XCTAssertEqual(role("Sent", delimiter: nil, marks: false), .sent)
        XCTAssertNil(role("INBOX.Sent", delimiter: "/", marks: false))
        XCTAssertNil(role("Sent.Old", delimiter: ".", marks: false))
    }

    /// A server that advertises SPECIAL-USE decides alone: its marks give the role whatever the folder is called, and a folder it didn't mark has none.
    func testWithSpecialUseOnlyTheServersMarksCount() {
        XCTAssertEqual(role("Odeslan&AOk-", .sent, marks: true), .sent)
        XCTAssertEqual(role("Sent", .drafts, marks: true), .drafts)
        XCTAssertNil(role("Drafts", marks: true))
        XCTAssertNil(role("Sent Items", [.hasNoChildren], marks: true))
    }

    /// Marks from a server without SPECIAL-USE are SwiftMail's guesses from substrings, so they are ignored and only the name counts.
    func testGuessedMarksAreIgnoredWithoutSpecialUse() {
        XCTAssertNil(role("Presentations", .sent, marks: false))
        XCTAssertNil(role("Contract drafts", .drafts, marks: false))
        XCTAssertEqual(role("Sent", .drafts, marks: false), .sent)
    }

    /// Every folder the server lists is returned, marked or not, and a marking server's roles come from its special-use listing even when the plain listing leaves them out.
    func testEveryListedFolderIsReturnedWithItsRole() {
        func folder(_ name: String, _ attributes: Mailbox.Info.Attributes = []) -> Mailbox.Info {
            Mailbox.Info(name: name, attributes: attributes, hierarchyDelimiter: "/")
        }
        let listed = [folder("INBOX"), folder("Odeslan&AOk-", .hasNoChildren), folder("Drafts"), folder("Faktury")]
        // SwiftMail adds \Inbox to INBOX itself when the server doesn't mark it, as IMAP names that folder.
        let marked = [folder("Odeslan&AOk-", [.hasNoChildren, .sent]), folder("INBOX", .inbox)]
        XCTAssertEqual(SwiftMailIMAPClient.folders(listed, special: marked, serverMarksRoles: true), [
            MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Odeslan&AOk-", role: .sent),
            MailFolder(name: "Drafts", role: nil), MailFolder(name: "Faktury", role: nil),
        ])
        let unmarked = [folder("INBOX"), folder("Presentations"), folder("Sent Items"), folder("Rozepsan&AOk-")]
        let guessed = [folder("Presentations", .sent), folder("Sent Items", .sent), folder("INBOX", .inbox)]
        XCTAssertEqual(SwiftMailIMAPClient.folders(unmarked, special: guessed, serverMarksRoles: false), [
            MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Presentations", role: nil),
            MailFolder(name: "Sent Items", role: .sent), MailFolder(name: "Rozepsan&AOk-", role: nil),
        ])
    }

    /// A UID that can't ask for one message (zero, negative, 2³²−1, which goes out as `*` for the newest, and beyond) is a missing message, not a crash or another mail, and never goes to the server.
    func testImpossibleUIDsAreMissingMessages() async throws {
        // Never connected: a request that reached the server would fail with a connection error, not messageNotFound.
        let client = try SwiftMailIMAPClient(MailServer(host: "127.0.0.1", port: 1, security: .plainText))
        let impossible = [-1, 0, Int(UInt32.max), Int(UInt32.max) + 1]
        let found = try await client.headers(impossible)
        XCTAssertEqual(found, [])
        for uid in impossible {
            do {
                _ = try await client.partData(uid: uid, section: "1")
                XCTFail("expected an error for \(uid)")
            } catch {
                XCTAssertEqual(error as? MailEngineError, .messageNotFound(uid: uid))
            }
            do {
                try await client.markSeen(uid: uid)
                XCTFail("expected an error for \(uid)")
            } catch {
                XCTAssertEqual(error as? MailEngineError, .messageNotFound(uid: uid))
            }
        }
    }
}
