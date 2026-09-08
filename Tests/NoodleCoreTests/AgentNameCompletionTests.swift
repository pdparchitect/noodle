import XCTest
@testable import NoodleCore

final class AgentNameCompletionTests: XCTestCase {
    private func request(_ text: String) -> AgentNameCompletion? {
        AgentNameCompletion.request(in: text, selection: NSRange(location: text.utf16.count, length: 0))
    }

    func testTriggersAndRejectsEmailAndNonTypingSelections() {
        XCTAssertEqual(request("@")?.query, "")
        XCTAssertEqual(request("Hello @An")?.query, "An")
        XCTAssertEqual(request("(@Mary Jane")?.query, "Mary Jane")
        XCTAssertNil(request("mail@example.com"))
        XCTAssertNil(request("https://example.com/@person"))
        XCTAssertNil(request("@Mara\nnext line"))
        XCTAssertNil(AgentNameCompletion.request(in: "@Mara", selection: NSRange(location: 0, length: 5)))
        XCTAssertNil(AgentNameCompletion.request(in: "@Mara", selection: NSRange(location: 90, length: 0)))
    }

    func testReplacementIsPlainTextAndPreservesSurroundingText() throws {
        let text = "Hi 👋 @An, please review this."
        let caret = (text as NSString).range(of: "@An").upperBound
        let completion = try XCTUnwrap(AgentNameCompletion.request(in: text, selection: NSRange(location: caret, length: 0)))
        XCTAssertEqual((text as NSString).replacingCharacters(in: completion.range, with: completion.replacement(name: "Angy", in: text)), "Hi 👋 Angy, please review this.")
        XCTAssertEqual(request("@An")?.replacement(name: "Angy", in: "@An"), "Angy ")
        let middle = try XCTUnwrap(AgentNameCompletion.request(in: "@Angy hello", selection: NSRange(location: 3, length: 0)))
        XCTAssertEqual(("@Angy hello" as NSString).replacingCharacters(in: middle.range, with: "Angy"), "Angy hello")
    }

    func testFiltersNamesAndPrioritizesGroupMembers() throws {
        let mara = AgentRecord(displayName: "Mara")
        let mary = AgentRecord(displayName: "Mary Jane")
        let angy = AgentRecord(displayName: "Angy")
        let completion = try XCTUnwrap(request("@ma"))
        XCTAssertEqual(completion.matches([mara, angy, mary], preferredIDs: [mary.id]).map(\.id), [mary.id, mara.id])
        XCTAssertEqual(request("@")?.matches([mara, angy], preferredIDs: []).count, 2)
        XCTAssertTrue(try XCTUnwrap(request("@zzzz")).matches([mara], preferredIDs: []).isEmpty)
    }
}
