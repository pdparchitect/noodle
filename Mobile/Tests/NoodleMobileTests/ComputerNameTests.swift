@testable import NoodleMobile
import Testing

/// A new computer or browser is named for the bot it is made for.
struct ComputerNameTests {
    @Test func namedForTheBot() {
        #expect(companionName("Computer", for: "Chloe") == "Chloe’s Computer")
        #expect(companionName("Browser", for: " Chloe ") == "Chloe’s Browser")
    }

    @Test func unnamedBotGetsThePlainNoun() {
        #expect(companionName("Computer", for: "  ") == "Computer")
    }
}
