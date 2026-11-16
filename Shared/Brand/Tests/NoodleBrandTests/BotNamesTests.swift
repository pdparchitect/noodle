import XCTest
@testable import NoodleBrand

final class BotNamesTests: XCTestCase {
    /// A suggested name is never one already taken, whatever its case, nor the one being replaced; when every
    /// name is taken, a number tells the new one apart.
    func testASuggestedNameIsNeverTaken() {
        let all = Set(BotNameGenerator.realNames)
        let free = "Ada"
        let taken = all.subtracting([free]).map { $0.uppercased() }
        XCTAssertEqual(BotNameGenerator.random(style: .real, avoiding: taken), free)
        XCTAssertNotEqual(BotNameGenerator.random(style: .real, excluding: free, avoiding: taken).lowercased(), "ada")

        let numbered = BotNameGenerator.random(style: .real, avoiding: Array(all))
        XCTAssertFalse(all.contains(numbered))
        XCTAssertTrue(numbered.hasSuffix(" 2"), numbered)
    }
}
