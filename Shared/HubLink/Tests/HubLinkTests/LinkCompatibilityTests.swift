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
        "enroll": #"{"request":{"enroll":{"deviceKey":"BEhnsDZStQfLMoSoKK4ZQvb0rOhU49qIX51h+o1GRTuRTSdeWLgusF4zPaU7KyvfPYKhUFhsFaMUDl8p2MoP7s8=","proof":"AQI=","deviceName":"Mac"}},"version":1}"#,
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
        "messageChanged": #"{"messageChanged":{"_0":{"attachments":[],"author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000C"}},"body":"Hi","conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"delivered":true,"id":"00000000-0000-0000-0000-00000000000A","reactions":[{"author":{"you":{}},"emoji":"👍"}]}}}"#,
        "botPhase": #"{"botPhase":{"botID":"00000000-0000-0000-0000-00000000000A","phase":"working"}}"#
    ]
    private static let invitation = #"{"endpoints":[{"host":"hub.local","port":38415}],"expires":1790000000,"hubKey":"BEhnsDZStQfLMoSoKK4ZQvb0rOhU49qIX51h+o1GRTuRTSdeWLgusF4zPaU7KyvfPYKhUFhsFaMUDl8p2MoP7s8=","hubName":"Hub","joinKey":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","userName":"Ada","version":1}"#

    private var draft: LinkBotDraft {
        LinkBotDraft(name: "Alfred", provider: "claude-code", profile: a, model: "opus", reasoningEffort: "high",
                     publicDescription: "Butler", backstory: "A butler.", avatarSymbolName: "sparkles", avatarColorIndex: 2,
                     avatarImageData: Data([1, 2]))
    }
    private var attachment: LinkAttachment { LinkAttachment(id: c, filename: "Report.pdf", mediaType: "application/pdf", byteCount: 7) }
    private var message: LinkMessage {
        LinkMessage(id: a, conversationID: b, author: .bot(c), body: "Hi", createdAt: date, delivered: true, attachments: [attachment])
    }

    private var nextDraft: (connection: LinkConnectionDraft, computer: LinkComputerDraft, browser: LinkBrowserDraft) {
        (LinkConnectionDraft(id: a, name: "Notion", endpoint: URL(string: "https://mcp.notion.com/mcp")!, description: "Notes", instructions: "Search first."),
         LinkComputerDraft(template: "ubuntu", name: "Workbench", description: "Builds", symbol: "hammer", colour: 3),
         LinkBrowserDraft(name: "Work", description: "Research", symbol: "briefcase", colour: 2))
    }
    private var nextRequests: [String: LinkRequest] {
        let d = nextDraft
        return [
            "connections": .connections, "saveConnection": .saveConnection(d.connection), "deleteConnection": .deleteConnection(id: a),
            "assignConnections": .assignConnections(botID: a, connectionIDs: [b]),
            "signIn": .signIn(connectionID: a, redirect: URL(string: "noodle://sign-in")!),
            "finishSignIn": .finishSignIn(connectionID: a, callback: URL(string: "noodle://sign-in?code=x")!),
            "computers": .computers, "computerTemplates": .computerTemplates, "createComputer": .createComputer(requestID: a, d.computer),
            "updateComputer": .updateComputer(id: a, d.computer), "assignComputers": .assignComputers(botID: a, computerIDs: [b]),
            "deleteComputer": .deleteComputer(id: a), "browsers": .browsers, "createBrowser": .createBrowser(d.browser),
            "updateBrowser": .updateBrowser(id: a, d.browser), "deleteBrowser": .deleteBrowser(id: a),
            "assignBrowsers": .assignBrowsers(botID: a, browserIDs: [b]),
            "openSurface": .openSurface(conversationID: b, attachmentID: c), "linkPreview": .linkPreview(conversationID: b, attachmentID: c),
            "messagePageBefore": .messagePage(LinkMessagePage(conversationID: b, before: 120, limit: 50)),
            "messagePageAfter": .messagePage(LinkMessagePage(conversationID: b, after: 3, limit: 100)),
        ]
    }
    private var nextResponses: [String: LinkResponse] {
        let d = nextDraft
        let connection = LinkConnection(draft: d.connection, iconData: Data([1]), botIDs: [b], signedIn: true, problem: nil)
        let computer = LinkComputer(id: a, name: "Workbench", description: "Builds", kind: "Linux", state: "Running", symbol: "hammer",
                                    colour: 3, icon: Data([2]), botIDs: [b])
        let browser = LinkBrowser(id: a, name: "Work", description: "Research", symbol: "briefcase", colour: 2, icon: Data([3]),
                                  paused: true, botIDs: [b])
        let link = LinkAttachment(id: c, filename: "Hacker News.webloc", mediaType: "application/x-webloc", byteCount: 180,
                                  url: URL(string: "noodlebrowser://00000000-0000-0000-0000-00000000000a?tab=00000000-0000-0000-0000-00000000000b"),
                                  card: LinkCardInfo(title: "Hacker News", detail: "https://news.ycombinator.com", image: Data([4]),
                                                     symbol: "globe", colour: 1, icon: Data([5]), capturedAt: date))
        return [
            "connections": .connections([connection]), "connection": .connection(connection),
            "computers": .computers([computer]), "computer": .computer(computer),
            "computerTemplates": .computerTemplates([LinkComputerTemplate(id: "ubuntu", name: "Ubuntu", description: "Linux", symbol: "terminal")]),
            "browsers": .browsers([browser]), "browser": .browser(browser), "picture": .picture(Data([6])), "noPicture": .picture(nil),
            "messagePage": .messages(LinkMessages(messages: [LinkMessage(id: a, conversationID: b, author: .bot(a), body: "Hi", createdAt: date,
                                                                         delivered: true)], count: 120, start: 70)),
            "linkMessage": .message(LinkMessage(id: a, conversationID: b, author: .bot(c), body: "Here", createdAt: date, delivered: true,
                                                attachments: [link])),
        ]
    }
    private var nextEvents: [String: LinkEvent] {
        let computer = LinkComputer(id: a, name: "Workbench", kind: "Linux", state: "Running", symbol: "hammer")
        return [
            "connectionsChanged": .connectionsChanged, "signInPage": .signInPage(connectionID: a, url: URL(string: "https://example.com/auth")!),
            "computersChanged": .computersChanged, "computerCreated": .computerCreated(requestID: a, computer: computer, error: nil),
            "computerFailed": .computerCreated(requestID: a, computer: nil, error: "No space"), "browsersChanged": .browsersChanged,
            "surfaceOpened": .surfaceOpened(sessionID: a), "surfaceFailed": .surfaceFailed(reason: "The computer is stopped."),
        ]
    }

    /// Everything added after the first release, as the next release sends it: managing
    /// connections, computers and browsers, links with their cards, live views and their pictures.
    func testMessagesOfTheNextReleaseStillRead() throws {
        XCTAssertEqual(Set(Self.nextRequestJSON.keys), Set(nextRequests.keys))
        for (name, json) in Self.nextRequestJSON {
            XCTAssertEqual(try LinkProtocol.decode(Data(json.utf8)).get(), nextRequests[name], name)
        }
        XCTAssertEqual(Set(Self.nextResponseJSON.keys), Set(nextResponses.keys))
        for (name, json) in Self.nextResponseJSON {
            XCTAssertEqual(try LinkProtocol.decodeResponse(Data(json.utf8)), nextResponses[name], name)
        }
        XCTAssertEqual(Set(Self.nextEventJSON.keys), Set(nextEvents.keys))
        for (name, json) in Self.nextEventJSON {
            XCTAssertEqual(LinkProtocol.decodeEvent(Data(json.utf8)), nextEvents[name], name)
        }
    }

    /// A live view's video and what goes back up it, byte for byte.
    func testLiveViewsOfTheNextReleaseStillRead() throws {
        let hex = "010000000100000000000000070140890000000000004082c000000000000200000002670100000002680200000003650304"
        let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
        let packet = SurfacePacket(sequence: 7, keyFrame: true, width: 800, height: 600,
                                   parameterSets: [Data([0x67, 1]), Data([0x68, 2])], sample: Data([0x65, 3, 4]))
        XCTAssertEqual(LinkSurface.message(bytes), .packets([packet]))
        let controls: [SurfaceControl] = [.input(.pointer(.down, x: 10, y: 20, clickCount: 2)), .input(.scroll(x: 1, y: 2, dx: 0, dy: -40)),
                                          .input(.key(.enter)), .input(.text("hi")), .view(width: 1206, height: 2622), .keyFrame]
        XCTAssertEqual(Self.controlJSON.map { SurfaceControl(Data($0.utf8)) }, controls)
    }

    private static let nextRequestJSON: [String: String] = [
        "messagePageBefore": #"{"version":1,"request":{"messagePage":{"_0":{"before":120,"limit":50,"conversationID":"00000000-0000-0000-0000-00000000000B"}}}}"#,
        "messagePageAfter": #"{"version":1,"request":{"messagePage":{"_0":{"conversationID":"00000000-0000-0000-0000-00000000000B","after":3,"limit":100}}}}"#,
        "assignBrowsers": #"{"version":1,"request":{"assignBrowsers":{"botID":"00000000-0000-0000-0000-00000000000A","browserIDs":["00000000-0000-0000-0000-00000000000B"]}}}"#,
        "assignComputers": #"{"request":{"assignComputers":{"botID":"00000000-0000-0000-0000-00000000000A","computerIDs":["00000000-0000-0000-0000-00000000000B"]}},"version":1}"#,
        "assignConnections": #"{"version":1,"request":{"assignConnections":{"botID":"00000000-0000-0000-0000-00000000000A","connectionIDs":["00000000-0000-0000-0000-00000000000B"]}}}"#,
        "browsers": #"{"version":1,"request":{"browsers":{}}}"#,
        "computerTemplates": #"{"version":1,"request":{"computerTemplates":{}}}"#,
        "computers": #"{"version":1,"request":{"computers":{}}}"#,
        "connections": #"{"version":1,"request":{"connections":{}}}"#,
        "createBrowser": #"{"version":1,"request":{"createBrowser":{"_0":{"description":"Research","symbol":"briefcase","colour":2,"name":"Work"}}}}"#,
        "createComputer": #"{"version":1,"request":{"createComputer":{"requestID":"00000000-0000-0000-0000-00000000000A","_1":{"template":"ubuntu","description":"Builds","symbol":"hammer","colour":3,"name":"Workbench"}}}}"#,
        "deleteBrowser": #"{"version":1,"request":{"deleteBrowser":{"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "deleteComputer": #"{"version":1,"request":{"deleteComputer":{"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "deleteConnection": #"{"version":1,"request":{"deleteConnection":{"id":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "finishSignIn": #"{"version":1,"request":{"finishSignIn":{"connectionID":"00000000-0000-0000-0000-00000000000A","callback":"noodle:\/\/sign-in?code=x"}}}"#,
        "linkPreview": #"{"version":1,"request":{"linkPreview":{"attachmentID":"00000000-0000-0000-0000-00000000000C","conversationID":"00000000-0000-0000-0000-00000000000B"}}}"#,
        "openSurface": #"{"version":1,"request":{"openSurface":{"attachmentID":"00000000-0000-0000-0000-00000000000C","conversationID":"00000000-0000-0000-0000-00000000000B"}}}"#,
        "saveConnection": #"{"version":1,"request":{"saveConnection":{"_0":{"id":"00000000-0000-0000-0000-00000000000A","description":"Notes","endpoint":"https:\/\/mcp.notion.com\/mcp","instructions":"Search first.","name":"Notion"}}}}"#,
        "signIn": #"{"version":1,"request":{"signIn":{"redirect":"noodle:\/\/sign-in","connectionID":"00000000-0000-0000-0000-00000000000A"}}}"#,
        "updateBrowser": #"{"version":1,"request":{"updateBrowser":{"id":"00000000-0000-0000-0000-00000000000A","_1":{"description":"Research","symbol":"briefcase","colour":2,"name":"Work"}}}}"#,
        "updateComputer": #"{"version":1,"request":{"updateComputer":{"id":"00000000-0000-0000-0000-00000000000A","_1":{"template":"ubuntu","description":"Builds","symbol":"hammer","colour":3,"name":"Workbench"}}}}"#
    ]
    private static let nextResponseJSON: [String: String] = [
        "messagePage": #"{"messages":{"_0":{"count":120,"start":70,"messages":[{"attachments":[],"reactions":[],"author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000A"}},"id":"00000000-0000-0000-0000-00000000000A","conversationID":"00000000-0000-0000-0000-00000000000B","createdAt":1790000000,"body":"Hi","delivered":true}]}}}"#,
        "browser": #"{"browser":{"_0":{"name":"Work","symbol":"briefcase","botIDs":["00000000-0000-0000-0000-00000000000B"],"id":"00000000-0000-0000-0000-00000000000A","icon":"Aw==","colour":2,"description":"Research","paused":true}}}"#,
        "browsers": #"{"browsers":{"_0":[{"paused":true,"id":"00000000-0000-0000-0000-00000000000A","symbol":"briefcase","botIDs":["00000000-0000-0000-0000-00000000000B"],"colour":2,"name":"Work","icon":"Aw==","description":"Research"}]}}"#,
        "computer": #"{"computer":{"_0":{"state":"Running","name":"Workbench","symbol":"hammer","botIDs":["00000000-0000-0000-0000-00000000000B"],"id":"00000000-0000-0000-0000-00000000000A","icon":"Ag==","colour":3,"description":"Builds","kind":"Linux"}}}"#,
        "computerTemplates": #"{"computerTemplates":{"_0":[{"symbol":"terminal","id":"ubuntu","name":"Ubuntu","description":"Linux"}]}}"#,
        "computers": #"{"computers":{"_0":[{"icon":"Ag==","colour":3,"kind":"Linux","description":"Builds","botIDs":["00000000-0000-0000-0000-00000000000B"],"id":"00000000-0000-0000-0000-00000000000A","symbol":"hammer","name":"Workbench","state":"Running"}]}}"#,
        "connection": #"{"connection":{"_0":{"signedIn":true,"botIDs":["00000000-0000-0000-0000-00000000000B"],"draft":{"id":"00000000-0000-0000-0000-00000000000A","description":"Notes","endpoint":"https:\/\/mcp.notion.com\/mcp","instructions":"Search first.","name":"Notion"},"iconData":"AQ=="}}}"#,
        "connections": #"{"connections":{"_0":[{"signedIn":true,"botIDs":["00000000-0000-0000-0000-00000000000B"],"draft":{"id":"00000000-0000-0000-0000-00000000000A","description":"Notes","endpoint":"https:\/\/mcp.notion.com\/mcp","instructions":"Search first.","name":"Notion"},"iconData":"AQ=="}]}}"#,
        "linkMessage": #"{"message":{"_0":{"reactions":[],"id":"00000000-0000-0000-0000-00000000000A","attachments":[{"id":"00000000-0000-0000-0000-00000000000C","mediaType":"application\/x-webloc","filename":"Hacker News.webloc","card":{"icon":"BQ==","symbol":"globe","colour":1,"title":"Hacker News","capturedAt":1790000000,"detail":"https:\/\/news.ycombinator.com","image":"BA=="},"byteCount":180,"url":"noodlebrowser:\/\/00000000-0000-0000-0000-00000000000a?tab=00000000-0000-0000-0000-00000000000b"}],"body":"Here","delivered":true,"createdAt":1790000000,"conversationID":"00000000-0000-0000-0000-00000000000B","author":{"bot":{"_0":"00000000-0000-0000-0000-00000000000C"}}}}}"#,
        "noPicture": #"{"picture":{}}"#,
        "picture": #"{"picture":{"_0":"Bg=="}}"#
    ]
    private static let nextEventJSON: [String: String] = [
        "browsersChanged": #"{"browsersChanged":{}}"#,
        "computerCreated": #"{"computerCreated":{"requestID":"00000000-0000-0000-0000-00000000000A","computer":{"name":"Workbench","symbol":"hammer","id":"00000000-0000-0000-0000-00000000000A","colour":0,"kind":"Linux","botIDs":[],"state":"Running"}}}"#,
        "computerFailed": #"{"computerCreated":{"error":"No space","requestID":"00000000-0000-0000-0000-00000000000A"}}"#,
        "computersChanged": #"{"computersChanged":{}}"#,
        "connectionsChanged": #"{"connectionsChanged":{}}"#,
        "signInPage": #"{"signInPage":{"connectionID":"00000000-0000-0000-0000-00000000000A","url":"https:\/\/example.com\/auth"}}"#,
        "surfaceFailed": #"{"surfaceFailed":{"reason":"The computer is stopped."}}"#,
        "surfaceOpened": #"{"surfaceOpened":{"sessionID":"00000000-0000-0000-0000-00000000000A"}}"#
    ]
    private static let controlJSON = [
        #"{"input":{"_0":{"pointer":{"_0":"down","clickCount":2,"x":10,"y":20}}}}"#,
        #"{"input":{"_0":{"scroll":{"dx":0,"dy":-40,"x":1,"y":2}}}}"#,
        #"{"input":{"_0":{"key":{"_0":"enter"}}}}"#,
        #"{"input":{"_0":{"text":{"_0":"hi"}}}}"#,
        #"{"view":{"height":2622,"width":1206}}"#,
        #"{"keyFrame":{}}"#
    ]

    func testVersion1RequestsStillRead() throws {
        let expected: [String: LinkRequest] = [
            "enroll": .enroll(deviceKey: try LinkPublicKey(x963: Data(base64Encoded: "BEhnsDZStQfLMoSoKK4ZQvb0rOhU49qIX51h+o1GRTuRTSdeWLgusF4zPaU7KyvfPYKhUFhsFaMUDl8p2MoP7s8=")!), proof: Data([1, 2]), deviceName: "Mac"), "status": .status, "subscribe": .subscribe, "bots": .bots,
            "createBot": .createBot(draft), "updateBot": .updateBot(id: a, draft), "deleteBot": .deleteBot(id: a),
            "messages": .messages(conversationID: b, after: 3),
            "send": .send(LinkOutgoingMessage(conversationID: b, id: a, body: "Hi", attachmentIDs: [c])),
            "upload": .upload(conversationID: b, attachment: attachment, offset: 0, data: Data([9])),
            "download": .download(conversationID: b, attachmentID: c, offset: 0),
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
            "messageChanged": .messageChanged(LinkMessage(id: a, conversationID: b, author: .bot(c), body: "Hi", createdAt: date,
                                                          delivered: true, reactions: [LinkReaction(author: .you, emoji: "👍")])),
            "botPhase": .botPhase(botID: a, phase: .working),
        ]
        for (name, json) in Self.events {
            XCTAssertEqual(LinkProtocol.decodeEvent(Data(json.utf8)), expected[name], name)
        }
    }

    /// Devices no longer lend tools to the Hub's bots; the Hub's bots use only the Hub's own.
    func testDeviceToolMessagesAreRetired() {
        let requests = [
            #"{"version":1,"request":{"publishTools":{"botID":"00000000-0000-0000-0000-00000000000A","catalogue":"W10="}}}"#,
            #"{"version":1,"request":{"toolResult":{"result":"e30=","callID":"00000000-0000-0000-0000-00000000000A"}}}"#,
        ]
        for json in requests {
            XCTAssertThrowsError(try LinkProtocol.decode(Data(json.utf8)).get(), json)
        }
        let call = #"{"toolCall":{"botID":"00000000-0000-0000-0000-00000000000B","callID":"00000000-0000-0000-0000-00000000000A","request":"e30="}}"#
        XCTAssertNil(LinkProtocol.decodeEvent(Data(call.utf8)))
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
