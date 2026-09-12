import XCTest
import FoundationModels
@testable import NoodleAppleRuntime

final class AppleHistoryReaderTests: XCTestCase {
    func testRepeatedPageStopsBeforeFetchingAgainAndKeepsSources() async throws {
        let reader = AppleHistoryReader()
        _ = try await reader.read(offset: 0, includeAssistantReplies: false) { .init(text: "User: The word is marigold.", nextOffset: 3_072) }
        do {
            _ = try await reader.read(offset: 0, includeAssistantReplies: false) {
                XCTFail("A repeated page must not be fetched again")
                return .init(text: "duplicate", nextOffset: nil)
            }
            XCTFail("Expected retrieval limit")
        } catch is AppleHistoryLimit {}
        let reference = await reader.reference
        XCTAssertEqual(reference, "User: The word is marigold.")
    }

    func testOverlappingPagesAndReadsPastEndStopBeforeFetching() async throws {
        let reader = AppleHistoryReader()
        _ = try await reader.read(offset: 0, includeAssistantReplies: false) { .init(text: "first", nextOffset: 3_072) }
        do {
            _ = try await reader.read(offset: 1, includeAssistantReplies: false) {
                XCTFail("A page number must not re-read overlapping bytes")
                return .init(text: "overlap", nextOffset: nil)
            }
            XCTFail("Expected continuation check")
        } catch is AppleHistoryLimit {}
        _ = try await reader.read(offset: 3_072, includeAssistantReplies: false) { .init(text: "last", nextOffset: nil) }
        do {
            _ = try await reader.read(offset: 6_144, includeAssistantReplies: false) {
                XCTFail("A completed history must not be fetched again")
                return .init(text: "past end", nextOffset: nil)
            }
            XCTFail("Expected end-of-history check")
        } catch is AppleHistoryLimit {}
    }

    func testTotalBytesAndPageCountAreBounded() async throws {
        let reader = AppleHistoryReader()
        _ = try await reader.read(offset: 0, includeAssistantReplies: false) { .init(text: String(repeating: "a", count: 3_100), nextOffset: 3_072) }
        _ = try await reader.read(offset: 3_072, includeAssistantReplies: false) { .init(text: String(repeating: "b", count: 3_100), nextOffset: 6_144) }
        do {
            _ = try await reader.read(offset: 6_144, includeAssistantReplies: false) { .init(text: String(repeating: "c", count: 3_100), nextOffset: nil) }
            XCTFail("Expected byte limit")
        } catch is AppleHistoryLimit {}
        let reference = await reader.reference
        XCTAssertEqual(reference.utf8.count, 6_202)

        let tinyPages = AppleHistoryReader()
        for offset in 0..<4 {
            _ = try await tinyPages.read(offset: offset, includeAssistantReplies: false) { .init(text: "page", nextOffset: offset + 1) }
        }
        do {
            _ = try await tinyPages.read(offset: 4, includeAssistantReplies: false) { .init(text: "page", nextOffset: nil) }
            XCTFail("Expected page limit")
        } catch is AppleHistoryLimit {}
    }

    func testHistoryScopesAndTurnsHaveIndependentBudgets() async throws {
        let reader = AppleHistoryReader()
        _ = try await reader.read(offset: 0, includeAssistantReplies: false) { .init(text: "user", nextOffset: nil) }
        _ = try await reader.read(offset: 0, includeAssistantReplies: true) { .init(text: "assistant", nextOffset: nil) }
        let nextTurn = AppleHistoryReader()
        _ = try await nextTurn.read(offset: 0, includeAssistantReplies: false) { .init(text: "new turn", nextOffset: nil) }
        let reference = await nextTurn.reference
        XCTAssertEqual(reference, "new turn")
    }

    func testChatRecoveryDoesNotRetryCancellationRefusalOrServiceErrors() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic")
        XCTAssertTrue(AppleModel.shouldRecoverChat(from: AppleHistoryLimit()))
        XCTAssertTrue(AppleModel.shouldRecoverChat(from: LanguageModelSession.ToolCallError(tool: HistoryFailureTool(), underlyingError: AppleHistoryLimit())))
        XCTAssertTrue(AppleModel.shouldRecoverChat(from: LanguageModelSession.GenerationError.exceededContextWindowSize(context)))
        XCTAssertFalse(AppleModel.shouldRecoverChat(from: CancellationError()))
        XCTAssertFalse(AppleModel.shouldRecoverChat(from: LanguageModelSession.GenerationError.guardrailViolation(context)))
        XCTAssertFalse(AppleModel.shouldRecoverChat(from: LanguageModelSession.GenerationError.rateLimited(context)))
        XCTAssertFalse(AppleModel.shouldRecoverChat(from: LanguageModelSession.GenerationError.assetsUnavailable(context)))
    }
}

@available(macOS 26, *)
private struct HistoryFailureTool: Tool {
    let name = "history"
    let description = "Synthetic history failure"
    @Generable struct Arguments { var offset: Int }
    func call(arguments: Arguments) async throws -> String { throw AppleHistoryLimit() }
}
