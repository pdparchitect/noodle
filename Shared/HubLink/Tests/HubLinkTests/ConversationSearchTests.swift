import XCTest
@testable import HubLink

final class ConversationSearchTests: XCTestCase {
    private func candidate(_ id: Int, group: Bool = false, name: String, about: String = "",
                           members: [String] = []) -> ConversationSearch.Candidate<Int> {
        .init(id: id, isGroup: group, name: name, about: about, members: members)
    }

    func testBlankSearchIsNoSearchAndTermsIgnoreCaseAccentsAndSurroundingSpace() throws {
        XCTAssertNil(ConversationSearch(" \n "))
        let search = try XCTUnwrap(ConversationSearch("  cafe "))
        XCTAssertEqual(search.term, "cafe")
        XCTAssertTrue(search.matches("Meet at the CAFÉ"))
        XCTAssertFalse(search.matches("Coffee"))
        let text = "Café, then cafe again"
        XCTAssertEqual(search.ranges(in: text).map { String(text[$0]) }, ["Café", "cafe"])
        let bold = search.highlighted(text).runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(bold.map { String(search.highlighted(text)[$0.range].characters) }, ["Café", "cafe"])
    }

    func testBotsMatchByNameBeforeDescriptionAndGroupsByNameThenMember() throws {
        let search = try XCTUnwrap(ConversationSearch("blake"))
        // Newest first, as the lists come.
        let sections = search.sections([
            candidate(1, name: "Theo", about: "Reviews Blake's pull requests"),
            candidate(2, group: true, name: "Media", members: ["Blake", "Chloe"]),
            candidate(3, name: "Blake"),
            candidate(4, group: true, name: "Blake's corner"),
            candidate(5, name: "Mila"),
            candidate(6, group: true, name: "General", about: "With blake on call"),
            candidate(7, group: true, name: "Quiet", members: ["Mila"])
        ])
        XCTAssertEqual(sections.bots, [3, 1])
        XCTAssertEqual(sections.groups, [4, 6, 2])
    }

    func testSnippetCutsAroundTheFirstMatchAtWordsAndFoldsWhitespace() throws {
        let search = try XCTUnwrap(ConversationSearch("blake"))
        XCTAssertEqual(search.snippet(of: "Ask\nBlake   now"), "Ask Blake now")
        XCTAssertNil(search.snippet(of: "Nobody here"))
        let long = Array(repeating: "word", count: 30).joined(separator: " ") + " then Blake said "
            + Array(repeating: "more", count: 40).joined(separator: " ")
        let snippet = try XCTUnwrap(search.snippet(of: long))
        XCTAssertTrue(snippet.hasPrefix("…word "), snippet)
        XCTAssertTrue(snippet.hasSuffix(" more…"), snippet)
        XCTAssertTrue(snippet.contains("then Blake said"), snippet)
        XCTAssertLessThanOrEqual(snippet.count, ConversationSearch.snippetLength + 2)
    }

    func testMessageMatchesComeNewestFirstUpToTheLimitAndSkipWhatHasNoText() throws {
        let search = try XCTUnwrap(ConversationSearch("violet"))
        let (first, second) = (UUID(), UUID())
        typealias Message = (id: UUID, date: Date, text: String?)
        let message = { (seconds: TimeInterval, text: String?) -> Message in (UUID(), Date(timeIntervalSince1970: seconds), text) }
        let conversations: [(id: UUID, messages: [Message])] = [
            (first, [message(1, "A violet notebook"), message(4, "Violet again"), message(5, nil)]),
            (second, [message(2, "Nothing"), message(3, "VIOLET ink")])
        ]
        let matches = search.messageMatches(in: conversations, limit: 2) { ($0.id, $0.date, $0.text) }
        XCTAssertEqual(matches.map(\.snippet), ["Violet again", "VIOLET ink"])
        XCTAssertEqual(matches.map(\.conversationID), [first, second])
        XCTAssertEqual(matches.first?.messageID, conversations[0].messages[1].id)
    }

    func testMentionsBesideAMatchingNameShowOnlyTheNewestUntilAllAreAsked() throws {
        let search = try XCTUnwrap(ConversationSearch("blake"))
        let matches = Array(1...5)
        XCTAssertEqual(search.shown(matches, besideNames: false, showingAll: false).shown, matches)
        let beside = search.shown(matches, besideNames: true, showingAll: false)
        XCTAssertEqual(beside.shown, [1, 2, 3])
        XCTAssertEqual(beside.hidden, 2)
        XCTAssertEqual(search.shown(matches, besideNames: true, showingAll: true).shown, matches)
    }
}
