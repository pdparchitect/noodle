import Foundation
@testable import HubLink
import XCTest

final class LinkRequestTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let encoder = JSONEncoder(), decoder = JSONDecoder()

    private func message(_ request: LinkRequestLine?) -> LinkMessage {
        var message = LinkMessage(id: UUID(), conversationID: UUID(), author: .bot(UUID()), body: "Asked Accounts",
                                  createdAt: date, delivered: true)
        message.request = request
        return message
    }

    func testRequestLinesTravelOnMessages() throws {
        let full = message(LinkRequestLine(helperName: "Accounts", status: .answered, text: "Total the invoices",
                                           answer: "The total is 120"))
        XCTAssertEqual(try decoder.decode(LinkMessage.self, from: encoder.encode(full)), full)
        // Someone the bot is shared with gets only how the request went.
        let statusOnly = message(LinkRequestLine(helperName: "Accounts", status: .withheld))
        let decoded = try decoder.decode(LinkMessage.self, from: encoder.encode(statusOnly))
        XCTAssertEqual(decoded, statusOnly)
        XCTAssertNil(decoded.request?.text)
        XCTAssertNil(decoded.request?.answer)
    }

    func testMessagesWithoutARequestLineStillDecode() throws {
        let plain = message(nil)
        let json = String(decoding: try encoder.encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("request"))
        XCTAssertNil(try decoder.decode(LinkMessage.self, from: Data(json.utf8)).request)
    }

    /// A newer Hub may send a status this app does not know. The message still shows, as the plain
    /// text an app without request lines shows, rather than a status it would get wrong.
    func testAnUnknownStatusStillDecodesTheMessage() throws {
        let original = message(LinkRequestLine(helperName: "Accounts", status: .waiting))
        let json = String(decoding: try encoder.encode(original), as: UTF8.self)
            .replacingOccurrences(of: "\"waiting\"", with: "\"rerouted\"")
        let decoded = try decoder.decode(LinkMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.body, "Asked Accounts")
        XCTAssertNil(decoded.request)
    }
}
