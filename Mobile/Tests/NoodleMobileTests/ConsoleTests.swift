import Foundation
import HubLink
@testable import NoodleMobile
import SwiftUI
import Testing

/// The console lists every noodlet the person's bots shared, games first, and is steered like a games console.
@MainActor @Suite struct ConsoleTests {
    private func hub() -> HubChats {
        HubChats(pairing: HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                     deviceName: "iPhone"))
    }

    private let thread = HubThread.bot(LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "claude"),
                                               createdAt: Date(timeIntervalSince1970: 0)))

    private func noodlet(_ name: String, id: UUID = UUID()) -> LinkAttachment {
        LinkAttachment(id: UUID(), filename: "\(name).noodlet", mediaType: "application/x-noodlet", byteCount: 0,
                       url: URL(string: "noodlet://\(id.uuidString)"))
    }

    private func title(_ attachment: LinkAttachment, on hub: HubChats, at seconds: TimeInterval, game: Bool = false) -> ConsoleTitle {
        ConsoleTitle(hub: hub, thread: thread, attachment: attachment, sharedAt: Date(timeIntervalSince1970: seconds), isGame: game)
    }

    @Test func aNoodletSharedTwiceIsListedOnceByItsNewestShare() {
        let studio = hub(), id = UUID()
        let old = noodlet("Racer", id: id), new = noodlet("Racer 2", id: id), other = noodlet("Notes")
        let titles = Console.titles([title(old, on: studio, at: 1), title(other, on: studio, at: 2), title(new, on: studio, at: 3)])
        #expect(titles.map(\.attachment.id) == [new.id, other.id])
    }

    @Test func gamesComeBeforeOtherNoodlets() {
        let studio = hub()
        let notes = title(noodlet("Notes"), on: studio, at: 3), racer = title(noodlet("Racer"), on: studio, at: 1, game: true)
        let shelves = Console.shelves([notes, racer])
        #expect(shelves.map(\.kind) == [.games, .noodlets])
        #expect(shelves.map { $0.titles.map(\.id) } == [[racer.id], [notes.id]])
        #expect(Console.shelves([notes]).map(\.kind) == [.noodlets])
        #expect(Console.shelves([]).isEmpty)
    }

    /// A noodlet is known as a game once its files are on this phone: it declared controls or the games category.
    @Test func aNoodletIsAGameByTheFilesThisPhoneKeeps() throws {
        let studio = hub()
        func keep(_ manifest: String) throws -> LinkAttachment {
            let id = UUID(), folder = studio.noodletCache.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("abc1")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("noodlet.json"))
            return noodlet("Kept", id: id)
        }
        let base = #""version":1,"title":"T","runtime":"web","entry":"index.html""#
        #expect(Console.isGame(try keep("{\(base),\"controls\":{\"buttons\":[{\"key\":\"space\"}]}}"), cache: studio.noodletCache))
        #expect(Console.isGame(try keep("{\(base),\"category\":\"games\"}"), cache: studio.noodletCache))
        #expect(!Console.isGame(try keep("{\(base)}"), cache: studio.noodletCache))
        #expect(!Console.isGame(noodlet("Never Opened"), cache: studio.noodletCache))
    }

    @Test func theSelectionMovesAlongAShelfAndBetweenShelves() {
        let counts = [3, 2]
        var selection = ConsoleSelection()
        selection = selection.moved(.left, counts: counts)
        #expect(selection == ConsoleSelection(shelf: 0, item: 0))
        selection = selection.moved(.right, counts: counts).moved(.right, counts: counts).moved(.right, counts: counts)
        #expect(selection == ConsoleSelection(shelf: 0, item: 2))
        selection = selection.moved(.down, counts: counts)
        #expect(selection == ConsoleSelection(shelf: 1, item: 1))
        #expect(selection.moved(.down, counts: counts) == selection)
        #expect(selection.moved(.up, counts: counts) == ConsoleSelection(shelf: 0, item: 1))
        #expect(ConsoleSelection(shelf: 4, item: 9).clamped(counts) == ConsoleSelection(shelf: 1, item: 1))
    }

    /// The front card sits in the middle, whole and facing; the others fan out to each side, smaller and turned away.
    @Test func theStackFansOutFromTheFrontCard() {
        let front = ConsoleStack.placement(offset: 0, cardWidth: 100)
        #expect(front.x == 0 && front.scale == 1 && front.angle == 0 && front.opacity == 1)
        let right = ConsoleStack.placement(offset: 1, cardWidth: 100)
        let left = ConsoleStack.placement(offset: -1, cardWidth: 100)
        #expect(right.x > 0 && left.x == -right.x && right.angle == -left.angle && right.angle != 0)
        let further = ConsoleStack.placement(offset: 2, cardWidth: 100)
        #expect(further.x > right.x && further.scale < right.scale)
        #expect(ConsoleStack.placement(offset: 4, cardWidth: 100).opacity == 0)
    }

    @Test func thePhonesControllerStepsOncePerPress() {
        #expect(ConsolePad.input(for: GamepadKeyChange(key: "left", pressed: true)) == .left)
        #expect(ConsolePad.input(for: GamepadKeyChange(key: "left", pressed: false)) == nil)
        #expect(ConsolePad.input(for: GamepadKeyChange(key: "enter", pressed: true)) == .choose)
        #expect(ConsolePad.input(for: GamepadKeyChange(key: "x", pressed: true)) == nil)
    }

    /// A controller starts the chosen noodlet only once the console has started, and moves nothing while one plays.
    @Test func choosingPlaysTheSelectedNoodlet() {
        let console = Console()
        let racer = title(noodlet("Racer"), on: hub(), at: 1, game: true)
        console.respond(.choose)
        #expect(console.playing == nil)
        console.booted = true
        console.play(racer)
        #expect(console.playing?.id == racer.id)
        console.leave()
        #expect(console.playing == nil)
    }
}
