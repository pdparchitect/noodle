@testable import MailEngine
import SwiftMail
import XCTest

/// Calls made at the same time on one session, run step by step on a `StepExecutor` so every run interleaves them the same way.
final class MailSessionTurnTests: XCTestCase {
    private var log: ServerLog!
    private var imap: PausingIMAP!
    private var session: MailSession!
    private var executor: StepExecutor!

    override func setUp() {
        log = ServerLog()
        imap = PausingIMAP(log: log)
        let account = MailAccount(address: "borek@mail.example.org", username: "borek@mail.example.org",
                                  imap: MailServer(host: "imap.seznam.cz", port: 993, security: .tls),
                                  smtp: MailServer(host: "smtp.seznam.cz", port: 465, security: .tls))
        session = MailSession(account: account, password: "secret", imap: imap, smtp: LoggingSMTP(log: log))
        executor = StepExecutor()
    }

    private static func query(_ folder: String) -> MessageQuery {
        var query = MessageQuery()
        query.folder = folder
        return query
    }

    /// Two lists made at once take turns, so each gets its own folder's mail, one sign-in serves both, and their SELECT, SEARCH and FETCH never interleave.
    func testConcurrentListsTakeTurns() throws {
        let session = session!
        imap.holdSelectOf = "Faktury"
        let faktury = executor.start { try await session.list(Self.query("Faktury")) }
        let inbox = executor.start { try await session.list(Self.query("INBOX")) }
        executor.runUntilIdle()
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury"])
        imap.release()
        executor.runUntilIdle()
        XCTAssertEqual(try faktury.value().map(\.subject), ["mail from Faktury"])
        XCTAssertEqual(try inbox.value().map(\.subject), ["mail from INBOX"])
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury", "SEARCH in Faktury", "FETCH in Faktury",
                                     "SELECT INBOX", "SEARCH in INBOX", "FETCH in INBOX"])
    }

    /// Every public call waits until the call before it is done, so none reaches a server while a list is under way, and then they run in the order they were made.
    func testEveryCallWaitsItsTurn() throws {
        let session = session!
        imap.holdSelectOf = "Faktury"
        let mail = OutgoingMail(to: ["ada@example.com"], subject: "x", body: "x")
        let list = executor.start { try await session.list(Self.query("Faktury")) }
        let folders = executor.start { try await session.folders() }
        let read = executor.start { try await session.read(uid: 1) }
        let attachment = executor.start { try await session.attachment(uid: 1, part: "1") }
        let draft = executor.start { try await session.draft(mail) }
        let send = executor.start { try await session.send(mail) }
        let check = executor.start { try await session.checkSending() }
        let close = executor.start { await session.close() }
        executor.runUntilIdle()
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury"])
        imap.release()
        executor.runUntilIdle()
        XCTAssertEqual(log.entries, [
            "LOGIN", "SELECT Faktury", "SEARCH in Faktury", "FETCH in Faktury",
            "LIST",
            "SELECT INBOX", "FETCH in INBOX", "BODY in INBOX",
            "SELECT INBOX", "FETCH in INBOX", "BODY in INBOX",
            "LIST", "APPEND to Drafts",
            "SMTP LOGIN", "SMTP SEND", "SMTP LOGOUT", "LIST", "APPEND to Sent",
            "SMTP LOGIN", "SMTP LOGOUT",
            "LOGOUT",
        ])
        XCTAssertEqual(try list.value().map(\.subject), ["mail from Faktury"])
        XCTAssertEqual(try folders.value().count, 3)
        XCTAssertEqual(try read.value().text, "text from INBOX")
        XCTAssertEqual(try attachment.value(), Data("text from INBOX".utf8))
        XCTAssertEqual(try draft.value().folder, "Drafts")
        XCTAssertTrue(try send.value().savedToSent)
        XCTAssertNoThrow(try check.value())
        XCTAssertNoThrow(try close.value())
    }

    /// A call cancelled while it waits for its turn leaves the queue with a CancellationError before reaching the server, and the call behind it still gets its turn.
    func testCancelledWaiterLeavesTheQueue() throws {
        let session = session!
        imap.holdSelectOf = "Faktury"
        let faktury = executor.start { try await session.list(Self.query("Faktury")) }
        let inbox = executor.start { try await session.list(Self.query("INBOX")) }
        let archive = executor.start { try await session.list(Self.query("Archiv")) }
        executor.runUntilIdle()
        inbox.task?.cancel()
        executor.runUntilIdle()
        XCTAssertThrowsError(try inbox.value()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury"])
        imap.release()
        executor.runUntilIdle()
        XCTAssertEqual(try faktury.value().map(\.subject), ["mail from Faktury"])
        XCTAssertEqual(try archive.value().map(\.subject), ["mail from Archiv"])
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury", "SEARCH in Faktury", "FETCH in Faktury",
                                     "SELECT Archiv", "SEARCH in Archiv", "FETCH in Archiv"])
    }

    /// A caller cancelled just as its turn is handed over passes the turn on with a CancellationError instead of starting its call.
    func testCancelledAtHandOverPassesTheTurnOn() throws {
        let session = session!
        imap.holdSelectOf = "Faktury"
        let faktury = executor.start { try await session.list(Self.query("Faktury")) }
        let inbox = executor.start { try await session.list(Self.query("INBOX")) }
        let archive = executor.start { try await session.list(Self.query("Archiv")) }
        executor.runUntilIdle()
        imap.release()
        // One step: the Faktury list finishes and hands the turn to the INBOX list, which has not run yet.
        executor.runNext()
        XCTAssertEqual(try faktury.value().map(\.subject), ["mail from Faktury"])
        inbox.task?.cancel()
        executor.runUntilIdle()
        XCTAssertThrowsError(try inbox.value()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try archive.value().map(\.subject), ["mail from Archiv"])
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury", "SEARCH in Faktury", "FETCH in Faktury",
                                     "SELECT Archiv", "SEARCH in Archiv", "FETCH in Archiv"])
    }

    /// A close cancelled while it waits still signs out once the call before it is done, because it cannot report the cancellation and must not leave the connection open.
    func testCancelledCloseStillSignsOutInTurn() throws {
        let session = session!
        imap.holdSelectOf = "Faktury"
        let faktury = executor.start { try await session.list(Self.query("Faktury")) }
        let close = executor.start { await session.close() }
        executor.runUntilIdle()
        close.task?.cancel()
        executor.runUntilIdle()
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury"])
        imap.release()
        executor.runUntilIdle()
        XCTAssertEqual(try faktury.value().map(\.subject), ["mail from Faktury"])
        XCTAssertNoThrow(try close.value())
        XCTAssertEqual(log.entries, ["LOGIN", "SELECT Faktury", "SEARCH in Faktury", "FETCH in Faktury", "LOGOUT"])
    }
}
