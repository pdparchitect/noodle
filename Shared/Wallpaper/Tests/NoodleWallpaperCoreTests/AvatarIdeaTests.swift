import XCTest
@testable import NoodleWallpaperCore

final class AvatarIdeaTests: XCTestCase {
    func testAlwaysAsksForAnAvatar() {
        XCTAssertEqual(AvatarIdea(name: "", description: "").phrases, ["avatar portrait"])
        XCTAssertNil(AvatarIdea(name: " ", description: "\n").summary)
    }

    func testNamesTheBot() {
        XCTAssertEqual(AvatarIdea(name: " Curious Otter ", description: "").phrases, ["avatar portrait", "Curious Otter"])
    }

    func testSummarisesTheDescriptionBeforeTheBackstory() {
        XCTAssertEqual(AvatarIdea(name: "Ada", description: " Reviews pull requests ", backstory: "A retired admiral.").summary,
                       "Reviews pull requests")
        XCTAssertEqual(AvatarIdea(name: "Ada", description: "", backstory: "A retired admiral.").summary, "A retired admiral.")
    }
}
