import Foundation
@testable import HubLink
import XCTest

/// Apps update at their own pace, so a message from an older or newer app must still read.
final class LinkCompatibilityTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try LinkProtocol.decoder.decode(type, from: Data(json.utf8))
    }

    func testFieldsAddedLaterMayBeMissing() throws {
        let id = UUID(), conversation = UUID()
        let message = try decode(LinkMessage.self,
            #"{"id":"\#(id)","conversationID":"\#(conversation)","author":{"you":{}},"body":"Hi","createdAt":0}"#)
        XCTAssertEqual(message.attachments, [])
        XCTAssertEqual(message.reactions, [])
        XCTAssertFalse(message.delivered)

        let draftJSON = #""draft":{"name":"Alfred","provider":"codex"}"#
        let bot = try decode(LinkBot.self, #"{"id":"\#(id)","conversationID":"\#(conversation)",\#(draftJSON),"createdAt":0}"#)
        XCTAssertNil(bot.phase)
        // A phase added after this app was built reads as unknown rather than failing the whole bot.
        let napping = try decode(LinkBot.self,
            #"{"id":"\#(id)","conversationID":"\#(conversation)",\#(draftJSON),"createdAt":0,"phase":"napping"}"#)
        XCTAssertNil(napping.phase)

        let status = try decode(LinkStatus.self, #"{"hubName":"Hub","userName":"Ada","planName":"Default"}"#)
        XCTAssertEqual(status.harnesses, [])
        XCTAssertEqual(status.endpoints, [])
        XCTAssertEqual(status.protocolVersion, 1)

        let draft = try decode(LinkBotDraft.self, #"{"name":"Alfred","provider":"codex"}"#)
        XCTAssertEqual(draft, LinkBotDraft(name: "Alfred", provider: "codex"))

        let file = try decode(LinkAttachment.self, #"{"id":"\#(id)","filename":"a.caf","mediaType":"audio/x-caf","byteCount":3}"#)
        XCTAssertNil(file.voice)
        let voice = LinkVoice(transcript: "Hello", duration: 2.5, waveform: [0.1, 0.9], localeIdentifier: "en_GB")
        let spoken = LinkAttachment(id: id, filename: "a.caf", mediaType: "audio/x-caf", byteCount: 3, voice: voice)
        XCTAssertEqual(try decode(LinkAttachment.self, String(decoding: try LinkProtocol.encoder.encode(spoken), as: UTF8.self)), spoken)

        let send = try decode(LinkOutgoingMessage.self, #"{"conversationID":"\#(conversation)","id":"\#(id)","body":"Hi"}"#)
        XCTAssertEqual(send.attachmentIDs, [])
    }

    func testFieldsAddedLaterAreIgnoredByOlderReaders() throws {
        let status = try decode(LinkStatus.self,
            #"{"hubName":"Hub","userName":"Ada","planName":"Default","harnesses":[],"endpoints":[],"protocolVersion":1,"weather":"sunny"}"#)
        XCTAssertEqual(status.hubName, "Hub")
    }
}

/// Version 1 exactly as the first release sends it. Every later release must still read
/// these, or older devices and Hubs stop understanding each other. Never edit an entry;
/// a new message gets a new entry.
final class LinkVersion1Tests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private static let requests: [String: String] = [
        "enroll": #"{"request":{"enroll":{"token":"t","deviceName":"Mac"}},"version":1}"#,
        "status": #"{"version":1,"request":{"status":{}}}"#,
        "subscribe": #"{"version":1,"request":{"subscribe":{}}}"#,
        "bots": #"{"request":{"bots":{}},"version":1}"#,
        "createBot": #"{"version":1,"request":{"createBot":{"_0":{"publicDescription":"Butler","profile":"00000000-0000-0000-0000-00000000000A","backstory":"A butler.","avatarSymbolName":"sparkles","avatarImageData":"AQI=","reasoningEffort":"high","avatarColorIndex":2,"provider":"claude-code","model":"opus","name":"Alfred"}}}}"#,
        "updateBot": #"{"version":1,"request":{"updateBot":{"_1":{"publicDescription":"Butler","provider":"claude-code","backstory":"A butler.","avatarImageData":"AQI=","model":"opus","avatarSymbolName":"sparkles","name":"Alfred","profile":"00000000-0000-0000-0000-00000000000A","avatarColorIndex":2,"reasoningEffort":"high"},"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "deleteBot": #"{"request":{"deleteBot":{"id":"00000000-0000-0000-0000-00000000000A"}},"version":1}"#,
        "messages": #"{"version":1,"request":{"messages":{"conversationID":"00000000-0000-0000-0000-00000000000B","after":3}}}"#,
        "send": #"{"version":1,"request":{"send":{"_0":{"body":"Hi","conversationID":"00000000-0000-0000-0000-00000000000B","id":"00000000-0000-0000-0000-00000000000A","attachmentIDs":["00000000-0000-0000-0000-00000000000C"]}}}}"#,
        "upload": #"{"request":{"upload":{"attachment":{"filename":"Report.pdf","mediaType":"application\/pdf","byteCount":7,"id":"00000000-0000-0000-0000-00000000000C"},"data":"CQ==","conversationID":"00000000-0000-0000-0000-00000000000B","offset":0}},"version":1}"#,
        "download": #"{"version":1,"request":{"download":{"attachmentID":"00000000-0000-0000-0000-00000000000C","offset":0,"conversationID":"00000000-0000-0000-0000-00000000000B"}}}"#,
        "publishTools": #"{"version":1,"request":{"publishTools":{"botID":"00000000-0000-0000-0000-00000000000A","catalogue":"W10="}}}"#,
        "toolResult": #"{"version":1,"request":{"toolResult":{"result":"e30=","callID":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "react": #"{"version":1,"request":{"react":{"_0":{"conversationID":"00000000-0000-0000-0000-00000000000B","messageID":"00000000-0000-0000-0000-00000000000A","emoji":"👍","present":true}}}}"#
    ]
    private static let responses: [String: String] = [
        "status": #"{"status":{"_0":{"endpoints":[{"host":"hub.local","port":38415}],"harnesses":[{"profile":"00000000-0000-0000-0000-00000000000B","profileName":"Work","provider":"codex","providerName":"Codex"}],"hubName":"Hub","planName":"Family","protocolVersion":1,"userName":"Ada"}}}"#,
        "bots": #"{"bots":{"_0":[{"conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"draft":{"avatarColorIndex":2,"avatarImageData":"AQI=","avatarSymbolName":"sparkles","backstory":"A butler.","model":"opus","name":"Alfred","profile":"00000000-0000-0000-0000-00000000000A","provider":"claude-code","publicDescription":"Butler","reasoningEffort":"high"},"id":"00000000-0000-0000-0000-00000000000A"}]}}"#,
        "bot": #"{"bot":{"_0":{"conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"draft":{"avatarColorIndex":2,"avatarImageData":"AQI=","avatarSymbolName":"sparkles","backstory":"A butler.","model":"opus","name":"Alfred","profile":"00000000-0000-0000-0000-00000000000A","provider":"claude-code","publicDescription":"Butler","reasoningEffort":"high"},"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "messages": #"{"messages":{"_0":{"count":1,"messages":[{"attachments":[{"byteCount":7,"filename":"Report.pdf","id":"00000000-0000-0000-0000-00000000000C","mediaType":"application\/pdf"}],"author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000C"}},"body":"Hi","conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"delivered":true,"id":"00000000-0000-0000-0000-00000000000A"}]}}}"#,
        "message": #"{"message":{"_0":{"attachments":[{"byteCount":7,"filename":"Report.pdf","id":"00000000-0000-0000-0000-00000000000C","mediaType":"application\/pdf"}],"author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000C"}},"body":"Hi","conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"delivered":true,"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "chunk": #"{"chunk":{"data":"CQ==","total":1}}"#,
        "done": #"{"done":{}}"#,
        "failure": #"{"failure":{"_0":"No"}}"#
    ]
    private static let events: [String: String] = [
        "conversationChanged": #"{"conversationChanged":{"conversationID":"00000000-0000-0000-0000-00000000000B","count":2}}"#,
        "botsChanged": #"{"botsChanged":{}}"#,
        "toolCall": #"{"toolCall":{"botID":"00000000-0000-0000-0000-00000000000B","callID":"00000000-0000-0000-0000-00000000000A","request":"e30="}}"#,
        "messageChanged": #"{"messageChanged":{"_0":{"attachments":[],"author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000C"}},"body":"Hi","conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"delivered":true,"id":"00000000-0000-0000-0000-00000000000A","reactions":[{"author":{"you":{}},"emoji":"👍"}]}}}"#,
        "botPhase": #"{"botPhase":{"botID":"00000000-0000-0000-0000-00000000000A","phase":"working"}}"#
    ]
    private static let invitation = #"{"endpoints":[{"host":"hub.local","port":38415}],"expires":1790000000,"hubKey":"BEhnsDZStQfLMoSoKK4ZQvb0rOhU49qIX51h+o1GRTuRTSdeWLgusF4zPaU7KyvfPYKhUFhsFaMUDl8p2MoP7s8=","hubName":"Hub","token":"t","userName":"Ada","version":1}"#

    private var draft: LinkBotDraft {
        LinkBotDraft(name: "Alfred", provider: "claude-code", profile: a, model: "opus", reasoningEffort: "high",
                     publicDescription: "Butler", backstory: "A butler.", avatarSymbolName: "sparkles", avatarColorIndex: 2,
                     avatarImageData: Data([1, 2]))
    }
    private var attachment: LinkAttachment { LinkAttachment(id: c, filename: "Report.pdf", mediaType: "application/pdf", byteCount: 7) }
    private var message: LinkMessage {
        LinkMessage(id: a, conversationID: b, author: .bot(c), body: "Hi", createdAt: date, delivered: true, attachments: [attachment])
    }

    func testVersion1RequestsStillRead() throws {
        let expected: [String: LinkRequest] = [
            "enroll": .enroll(token: "t", deviceName: "Mac"), "status": .status, "subscribe": .subscribe, "bots": .bots,
            "createBot": .createBot(draft), "updateBot": .updateBot(id: a, draft), "deleteBot": .deleteBot(id: a),
            "messages": .messages(conversationID: b, after: 3),
            "send": .send(LinkOutgoingMessage(conversationID: b, id: a, body: "Hi", attachmentIDs: [c])),
            "upload": .upload(conversationID: b, attachment: attachment, offset: 0, data: Data([9])),
            "download": .download(conversationID: b, attachmentID: c, offset: 0),
            "publishTools": .publishTools(botID: a, catalogue: Data("[]".utf8)),
            "toolResult": .toolResult(callID: a, result: Data("{}".utf8), error: nil),
            "react": .react(LinkReactionChange(conversationID: b, messageID: a, emoji: "👍", present: true)),
        ]
        XCTAssertEqual(Set(Self.requests.keys), Set(expected.keys))
        for (name, json) in Self.requests {
            XCTAssertEqual(try LinkProtocol.decode(Data(json.utf8)).get(), expected[name], name)
        }
    }

    func testVersion1ResponsesStillRead() throws {
        let status = LinkStatus(hubName: "Hub", userName: "Ada", planName: "Family",
                                harnesses: [LinkHarness(provider: "codex", providerName: "Codex", profile: b, profileName: "Work")],
                                endpoints: [LinkEndpoint(host: "hub.local", port: 38415)])
        let bot = LinkBot(id: a, conversationID: b, draft: draft, createdAt: date)
        let expected: [String: LinkResponse] = [
            "status": .status(status), "bots": .bots([bot]), "bot": .bot(bot),
            "messages": .messages(LinkMessages(messages: [message], count: 1)), "message": .message(message),
            "chunk": .chunk(data: Data([9]), total: 1), "done": .done, "failure": .failure("No"),
        ]
        XCTAssertEqual(Set(Self.responses.keys), Set(expected.keys))
        for (name, json) in Self.responses {
            XCTAssertEqual(try LinkProtocol.decodeResponse(Data(json.utf8)), expected[name], name)
        }
    }

    func testVersion1EventsStillRead() {
        let expected: [String: LinkEvent] = [
            "conversationChanged": .conversationChanged(conversationID: b, count: 2), "botsChanged": .botsChanged,
            "toolCall": .toolCall(callID: a, botID: b, request: Data("{}".utf8)),
            "messageChanged": .messageChanged(LinkMessage(id: a, conversationID: b, author: .bot(c), body: "Hi", createdAt: date,
                                                          delivered: true, reactions: [LinkReaction(author: .you, emoji: "👍")])),
            "botPhase": .botPhase(botID: a, phase: .working),
        ]
        for (name, json) in Self.events {
            XCTAssertEqual(LinkProtocol.decodeEvent(Data(json.utf8)), expected[name], name)
        }
    }

    func testVersion1InvitationsStillRead() throws {
        let invitation = try LinkProtocol.decoder.decode(LinkInvitation.self, from: Data(Self.invitation.utf8))
        XCTAssertEqual(invitation.hubName, "Hub")
        XCTAssertEqual(invitation.userName, "Ada")
        XCTAssertEqual(invitation.endpoints, [LinkEndpoint(host: "hub.local", port: 38415)])
        XCTAssertEqual(invitation.expires, date)
        XCTAssertEqual(invitation.version, 1)
    }
}
