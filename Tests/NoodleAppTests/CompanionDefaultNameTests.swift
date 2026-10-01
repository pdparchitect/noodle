import BrowserBridge
import ComputerBridge
import XCTest
@testable import Noodle

/// A new computer or browser is named for the bot it is made for.
@MainActor final class CompanionDefaultNameTests: HiddenViewTests {
    func testNewBrowserIsNamedForItsBot() async throws {
        let sheet = host(NewBrowserSheet(bot: "Chloe", create: { _ in RemoteBrowser(id: UUID(), name: "") }, onCreated: { _ in }))
        _ = try await nameField(in: sheet, name: "Chloe’s Browser")
    }

    func testNewComputerIsNamedForItsBotWhateverTheKind() async throws {
        let sheet = host(NewComputerSheet(bot: "Chloe", templates: {
            [ComputerTemplateSummary(id: "desktop", name: "Desktop", description: "", symbol: "desktopcomputer")]
        }, create: { _ in throw CancellationError() }, onCreated: { _ in }))
        _ = try await nameField(in: sheet, name: "Chloe’s Computer")
    }

    func testUnnamedBotGetsThePlainNoun() {
        XCTAssertEqual(companionName("Computer", for: "  "), "Computer")
        XCTAssertEqual(companionName("Browser", for: " Chloe "), "Chloe’s Browser")
    }
}
