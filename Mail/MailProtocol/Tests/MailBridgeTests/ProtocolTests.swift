import XCTest
@testable import MailBridge

final class ProtocolTests: XCTestCase {
    private let mailbox = UUID()

    private func request(_ operation: MailOperation, _ change: (inout MailRequest) -> Void = { _ in }) -> MailRequest {
        var request = MailRequest(operation, mailboxID: mailbox)
        change(&request)
        return request
    }

    private func message(_ request: MailRequest) -> String? {
        do { try request.validate(); return nil } catch { return (error as? MailError)?.message ?? "\(error)" }
    }

    /// Every field survives the trip through JSON, which is how requests cross the socket.
    func testRequestsRoundTripThroughJSON() throws {
        let sent = request(.search) {
            $0.folder = "Odeslan&AOk-"
            var query = MailQuery(); query.from = "someone@example.com"; query.since = "2026-10-01"; query.limit = 5; query.beforeUID = 900
            $0.query = query; $0.markRead = false; $0.maxCharacters = 5_000
        }
        let received = try MailRequest.read(JSONEncoder().encode(sent))
        XCTAssertEqual(received.id, sent.id)
        XCTAssertEqual(received.operation, .search)
        XCTAssertEqual(received.mailboxID, mailbox)
        XCTAssertEqual(received.folder, "Odeslan&AOk-")
        XCTAssertEqual(received.query, sent.query)
        XCTAssertEqual(received.maxCharacters, 5_000)
    }

    /// Well-formed requests of every kind pass.
    func testWellFormedRequestsPass() {
        XCTAssertNil(message(MailRequest(.mailboxes)))
        XCTAssertNil(message(request(.folders)))
        XCTAssertNil(message(request(.list) { $0.folder = "INBOX"; var q = MailQuery(); q.unreadOnly = true; q.limit = 100; $0.query = q }))
        XCTAssertNil(message(request(.search) { var q = MailQuery(); q.text = ""; q.before = "2026-01-31"; $0.query = q }))
        XCTAssertNil(message(request(.read) { $0.uid = 4_294_967_294; $0.maxCharacters = 200_000 }))
        XCTAssertNil(message(request(.attachment) { $0.uid = 1; $0.part = "2.1" }))
    }

    /// Malformed requests are refused with a sentence a bot can act on, before any mail server sees them.
    func testMalformedRequestsAreRefused() {
        XCTAssertEqual(message(MailRequest(.folders)), "Specify a mailbox.")
        XCTAssertEqual(message(request(.list) { $0.folder = "INBOX\r\nA1 LOGOUT" }), "Invalid folder name.")
        XCTAssertEqual(message(request(.list) { $0.folder = "" }), "Invalid folder name.")
        XCTAssertEqual(message(request(.list) { $0.folder = String(repeating: "a", count: 1_001) }), "Invalid folder name.")
        XCTAssertEqual(message(request(.search) { var q = MailQuery(); q.subject = "x\ny"; $0.query = q }), "Invalid search text.")
        XCTAssertEqual(message(request(.search) { var q = MailQuery(); q.since = "2026-13-01"; $0.query = q }), "Use YYYY-MM-DD for dates.")
        XCTAssertEqual(message(request(.search) { var q = MailQuery(); q.before = "2026-1-1"; $0.query = q }), "Use YYYY-MM-DD for dates.")
        XCTAssertEqual(message(request(.list) { var q = MailQuery(); q.limit = 0; $0.query = q }), "The limit must be 1 to 100.")
        XCTAssertEqual(message(request(.list) { var q = MailQuery(); q.limit = 101; $0.query = q }), "The limit must be 1 to 100.")
        XCTAssertEqual(message(request(.list) { var q = MailQuery(); q.beforeUID = 0; $0.query = q }), "Invalid message UID.")
        XCTAssertEqual(message(request(.read)), "Specify the message UID.")
        XCTAssertEqual(message(request(.read) { $0.uid = 4_294_967_295 }), "Invalid message UID.")
        XCTAssertEqual(message(request(.read) { $0.uid = 3; $0.maxCharacters = 999 }), "max_chars must be 1000 to 200000.")
        XCTAssertEqual(message(request(.attachment) { $0.uid = 3 }), "Specify the attachment part from read.")
        XCTAssertEqual(message(request(.attachment) { $0.uid = 3; $0.part = "1..2" }), "Invalid attachment part.")
        XCTAssertEqual(message(request(.attachment) { $0.uid = 3; $0.part = "a" }), "Invalid attachment part.")
        XCTAssertEqual(message(request(.attachment) { $0.uid = 3; $0.part = "1\u{0301}" }), "Invalid attachment part.")
    }

    /// A day means 12:00 UTC on that day; impossible days are refused.
    func testDaysAreNoonUTC() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(MailRequest.day("2026-02-28"))
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 2, 28, 12])
        XCTAssertNil(MailRequest.day("2026-02-30"))
        XCTAssertNil(MailRequest.day("2026-2-28"))
        XCTAssertNil(MailRequest.day("yesterday"))
    }

    /// A request this build can't decode, such as a newer operation, asks for an update instead of failing silently.
    func testUnknownOperationsAskForANewerApp() {
        let data = Data(#"{"version":1,"id":"\#(UUID().uuidString)","operation":"send"}"#.utf8)
        XCTAssertThrowsError(try MailRequest.read(data)) { error in
            XCTAssertTrue((error as? MailError)?.message.contains("newer") == true)
        }
    }

    /// A response carries its error to the caller, and a newer response version is refused.
    func testResponsesCarryErrors() throws {
        XCTAssertThrowsError(try MailResponse(error: "The mailbox is gone.").checked()) { error in
            XCTAssertEqual(error as? MailError, MailError("The mailbox is gone."))
        }
        var newer = MailResponse(); newer.version = 2
        XCTAssertThrowsError(try newer.checked())
        var fine = MailResponse(); fine.mailboxes = [RemoteMailbox(id: mailbox, name: "Bořek", address: "borek@mail.example.org")]
        XCTAssertEqual(try fine.checked().mailboxes?.first?.name, "Bořek")
    }
}
