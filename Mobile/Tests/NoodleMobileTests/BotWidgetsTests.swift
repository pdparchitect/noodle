import Foundation
import HubLink
import Testing
import UIKit
@testable import NoodleMobile

@MainActor @Suite struct BotWidgetsTests {
    /// A Hub's key as spaces name it, base64 with the characters a link has to escape.
    private static let hub = "BJx+Qm/9a7c="

    private static func bot(_ name: String, hub: String = hub) -> WidgetBot {
        WidgetBot(hub: hub, conversationID: UUID(), name: name, hubName: "Studio")
    }

    private static func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    /// The widgets read back what the app saved; saving the same again writes nothing, so widgets reload only on a change.
    @Test func theShelfKeepsTheBotsAndSpaces() throws {
        let shelf = BotWidgetShelf(rootURL: Self.folder())
        #expect(shelf.load() == WidgetShelf())
        var scout = Self.bot("Scout")
        scout.image = Data([1, 2, 3])
        let saved = WidgetShelf(bots: [scout, Self.bot("Atlas")], spaces: [WidgetSpace(id: Self.hub, name: "Studio", bots: [scout.id])])

        #expect(try shelf.save(saved))
        #expect(shelf.load() == saved)
        #expect(try !shelf.save(saved))
    }

    /// All holds every bot. A space holds its own in its order, leaving out bots no longer there, and a space gone holds none.
    @Test func aSpaceHoldsItsBotsInItsOrder() {
        let scout = Self.bot("Scout"), atlas = Self.bot("Atlas"), nova = Self.bot("Nova", hub: "other")
        let work = UUID().uuidString
        let shelf = WidgetShelf(bots: [scout, atlas, nova], spaces: [
            WidgetSpace(id: Self.hub, name: "Studio", bots: [atlas.id, scout.id]),
            WidgetSpace(id: work, name: "Work", bots: [nova.id, WidgetBot.id(hub: Self.hub, conversationID: UUID()), scout.id]),
        ])

        #expect(shelf.bots(in: WidgetSpace.allID) == [scout, atlas, nova])
        #expect(shelf.bots(in: Self.hub) == [atlas, scout])
        #expect(shelf.bots(in: work) == [nova, scout])
        #expect(shelf.bots(in: UUID().uuidString) == nil)
        #expect(shelf.bot(atlas.id) == atlas)
        #expect(shelf.namesHubs)
        #expect(!WidgetShelf(bots: [scout, atlas]).namesHubs)
    }

    /// A widget's link names the conversation as the Mac's widgets do, and its Hub by key, whatever characters that has.
    /// Any other link, such as an invitation, is not a widget's.
    @Test func aWidgetsLinkLeadsBackToItsBot() throws {
        let bot = Self.bot("Scout")
        let url = WidgetLink(bot).url

        #expect(url.scheme == "noodle")
        #expect(url.host == "conversation")
        #expect(url.lastPathComponent == bot.conversationID.uuidString.lowercased())
        #expect(WidgetLink(url: url) == WidgetLink(hub: Self.hub, conversationID: bot.conversationID))
        #expect(WidgetLink(url: try #require(URL(string: "noodle://join-hub?invitation=abc"))) == nil)
        #expect(WidgetLink(url: try #require(URL(string: "noodle://conversation/\(bot.conversationID.uuidString)"))) == nil)
        #expect(WidgetLink(url: try #require(URL(string: "noodle://conversation/not-a-uuid?hub=abc"))) == nil)
    }

    /// A widget's call button links to the same conversation by noodle://call, which opens the chat and calls the bot.
    @Test func aCallButtonsLinkCallsItsBot() throws {
        let bot = Self.bot("Scout")
        let url = WidgetLink(bot, call: true).url

        #expect(url.scheme == "noodle")
        #expect(url.host == "call")
        #expect(url.lastPathComponent == bot.conversationID.uuidString.lowercased())
        #expect(WidgetLink(url: url) == WidgetLink(hub: Self.hub, conversationID: bot.conversationID, call: true))
        #expect(WidgetLink(url: WidgetLink(bot).url)?.call == false)
        #expect(WidgetLink(url: try #require(URL(string: "noodle://call/\(bot.conversationID.uuidString)"))) == nil)
        #expect(WidgetLink(url: try #require(URL(string: "noodle://call/not-a-uuid?hub=abc"))) == nil)
    }

    /// Call Agent, from Shortcuts or the Action Button, calls a bot that takes calls and opens the chat of one that does not.
    @Test func callingABotThatTakesNoCallsOpensItsChat() {
        var scout = Self.bot("Scout")
        #expect(WidgetLink(calling: scout) == WidgetLink(scout))
        scout.callable = true
        #expect(WidgetLink(calling: scout) == WidgetLink(scout, call: true))
    }

    /// Bots saved before widgets knew about calls read back as not callable; the flag is kept once saved.
    @Test func botsSavedBeforeCallsAreNotCallable() throws {
        let conversationID = UUID()
        let old = Data(#"{"bots":[{"conversationID":"\#(conversationID.uuidString)","hub":"abc","hubName":"Studio","name":"Scout"}],"spaces":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(WidgetShelf.self, from: old)
        #expect(decoded.bots == [WidgetBot(hub: "abc", conversationID: conversationID, name: "Scout", hubName: "Studio")])
        #expect(decoded.bots.first?.callable == false)

        let shelf = BotWidgetShelf(rootURL: Self.folder())
        var scout = Self.bot("Scout")
        scout.callable = true
        try shelf.save(WidgetShelf(bots: [scout, Self.bot("Atlas")]))
        #expect(shelf.load().bots.map(\.callable) == [true, false])
    }

    /// The Bot widget shows its call button only for a bot that takes calls, and only while the widget's Show Call
    /// Button is on, as it is until the person turns it off.
    @Test func theCallButtonShowsForABotThatTakesCallsUnlessTurnedOff() {
        var scout = Self.bot("Scout")
        #expect(!scout.showsCallButton())
        #expect(!scout.showsCallButton(setting: true))

        scout.callable = true
        #expect(scout.showsCallButton())
        #expect(scout.showsCallButton(setting: true))
        #expect(!scout.showsCallButton(setting: false))
    }

    /// Publishing tells the widgets which bots take calls, as the chat's Call button does.
    @Test func publishingMarksBotsThatTakeCalls() {
        let shelf = BotWidgetShelf(rootURL: Self.folder())
        let face = BotFace(LinkBotDraft(name: "Scout", provider: "claude"), id: UUID())
        let caller = BotWidgetPublisher.Source.Bot(hub: Self.hub, hubName: "Studio", conversationID: UUID(), face: face, canCall: true)
        let quiet = BotWidgetPublisher.Source.Bot(hub: Self.hub, hubName: "Studio", conversationID: UUID(), face: face)

        BotWidgetPublisher(shelf: shelf).publish(BotWidgetPublisher.Source(bots: [caller, quiet]))

        #expect(shelf.load().bots.map(\.callable) == [true, false])
    }

    /// Opening a widget's call link calls the bot only while it takes calls and is not on one already; any other
    /// opening, as a tapped notification's, only opens the chat.
    @Test func onlyACallButtonStartsACall() {
        func thread(canCall: Bool) -> HubThread {
            .bot(LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "claude"),
                         createdAt: Date(), canCall: canCall))
        }
        let caller = thread(canCall: true), quiet = thread(canCall: false)
        let call = NotificationRoute(topic: "topic", conversation: caller.conversationID, call: true)
        let open = NotificationRoute(topic: "topic", conversation: caller.conversationID)

        #expect(AgentsView.startsCall(call, to: caller, calling: nil, canCallNow: true))
        #expect(AgentsView.startsCall(call, to: caller, calling: UUID(), canCallNow: true))
        #expect(!AgentsView.startsCall(call, to: caller, calling: caller.id, canCallNow: true))
        #expect(!AgentsView.startsCall(call, to: quiet, calling: nil, canCallNow: true))
        #expect(!AgentsView.startsCall(open, to: caller, calling: nil, canCallNow: true))
        // A bot that is not running now only has its chat opened.
        #expect(!AgentsView.startsCall(call, to: caller, calling: nil, canCallNow: false))
    }

    /// The app draws each bot's picture for the widgets, which cannot draw its symbol and colours themselves.
    @Test func publishingDrawsEachBotsPicture() throws {
        let shelf = BotWidgetShelf(rootURL: Self.folder())
        let face = BotFace(LinkBotDraft(name: "Scout", provider: "claude", avatarSymbolName: "star", avatarColorIndex: 2), id: UUID())
        let bot = BotWidgetPublisher.Source.Bot(hub: Self.hub, hubName: "Studio", conversationID: UUID(), face: face)
        let space = WidgetSpace(id: Self.hub, name: "Studio", bots: [bot.id])

        BotWidgetPublisher(shelf: shelf).publish(BotWidgetPublisher.Source(bots: [bot], spaces: [space]))

        let saved = shelf.load()
        #expect(saved.bots.map(\.name) == ["Scout"])
        #expect(saved.bots.map(\.id) == [bot.id])
        #expect(saved.spaces == [space])
        let picture = try #require(saved.bots.first?.image.flatMap(UIImage.init(data:))?.cgImage)
        #expect(picture.width == Int(BotWidgetPublisher.pictureSize * 3))
    }
}
