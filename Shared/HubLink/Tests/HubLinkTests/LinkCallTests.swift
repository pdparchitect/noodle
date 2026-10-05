import Foundation
@testable import HubLink
import XCTest

final class LinkCallTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testACallStartsWithItsOfferAndItsEventsTravelTheChannel() throws {
        let start = LinkCallStart(conversationID: UUID(), offer: "v=0 offer")
        guard case .success(.startCall(let decoded)) = LinkProtocol.decode(try LinkProtocol.encode(.startCall(start))) else {
            return XCTFail("The request did not survive the link")
        }
        XCTAssertEqual(decoded, start)

        let events: [LinkCallEvent] = [.answer("v=0 answer"), .started, .line(LinkCallLine(speaker: .you, text: "Hi", at: date)),
                                       .line(LinkCallLine(speaker: .bot, text: "Hello", at: nil)), .ended(nil), .ended("The bot stopped.")]
        for event in events { XCTAssertEqual(LinkCallEvent(event.encoded), event) }
        XCTAssertNil(LinkCallEvent(Data("not json".utf8)))
    }

    func testCallsTravelOnMessagesAndBotsAndOlderPayloadsStillDecode() throws {
        var message = LinkMessage(id: UUID(), conversationID: UUID(), author: .you, body: "Voice call", createdAt: date, delivered: true)
        message.call = LinkCallRecord(botID: UUID(), endedAt: date, lines: [LinkCallLine(speaker: .bot, text: "Done.", at: date)])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LinkMessage.self, from: encoder.encode(message)), message)

        var plain = message
        plain.call = nil
        XCTAssertNil(try decoder.decode(LinkMessage.self, from: encoder.encode(plain)).call)

        var draft = LinkBotDraft(name: "Yuki", provider: "codex")
        XCTAssertNil(try decoder.decode(LinkBotDraft.self, from: encoder.encode(draft)).voice)
        draft.voice = "maple"
        XCTAssertEqual(try decoder.decode(LinkBotDraft.self, from: encoder.encode(draft)).voice, "maple")

        var bot = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: date)
        XCTAssertFalse(try decoder.decode(LinkBot.self, from: encoder.encode(bot)).canCall)
        bot.canCall = true
        XCTAssertTrue(try decoder.decode(LinkBot.self, from: encoder.encode(bot)).canCall)

        var harness = LinkHarness(provider: "codex", providerName: "Codex", profileName: nil)
        XCTAssertEqual(try decoder.decode(LinkHarness.self, from: encoder.encode(harness)).voices, [])
        harness.voices = [LinkCallVoice(id: "maple", name: "Maple", presentation: .feminine)]
        XCTAssertEqual(try decoder.decode(LinkHarness.self, from: encoder.encode(harness)).voices, harness.voices)
    }
}
