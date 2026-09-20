import Foundation
import NoodleCore
import XCTest
@testable import Noodle

private final class HostLinkFixture: AgentHostRequestLink {
    var onFailure: ((String) -> Void)?
    var reply: ((Data?, String?) -> Void)?
    var invalidations = 0
    func invalidate() { invalidations += 1 }
}

private struct HostAnswer: Codable, Equatable { let name: String }

@MainActor final class AgentHostRequestTests: XCTestCase {
    private let link = HostLinkFixture()
    private var timers: [RoutingGate<Void>] = []

    override func tearDown() async throws {
        timers.forEach { $0.resolve(.failure(CancellationError())) }
    }

    /// The timeout waits on a gate, so no test depends on how long anything takes.
    private func ask(disconnected: String? = nil) async throws -> Task<HostAnswer, Error> {
        let link = link, timer = RoutingGate<Void>()
        timers.append(timer)
        let request = AgentHostRequest<HostAnswer, HostLinkFixture>(link, sleep: { _ in try await timer.value() })
        let task = Task { @MainActor in
            try await request.load(timeout: .seconds(1), noReply: "Nothing came back.", timedOut: "Took too long.",
                                   disconnected: disconnected) { $0.reply = $1 }
        }
        try await RuntimeClockFixture().waitUntil { link.reply != nil }
        return task
    }

    private func message(_ task: Task<HostAnswer, Error>) async -> String? {
        do { _ = try await task.value; return nil } catch { return error.localizedDescription }
    }

    func testReplyIsDecodedAndTheConnectionIsClosed() async throws {
        let task = try await ask()
        link.reply?(try JSONEncoder().encode(HostAnswer(name: "fixture")), nil)
        let answer = try await task.value
        XCTAssertEqual(answer, HostAnswer(name: "fixture"))
        XCTAssertEqual(link.invalidations, 1)
    }

    func testHostErrorMissingReplyAndUnreadableReplyAllFail() async throws {
        var task = try await ask()
        link.reply?(Data("{}".utf8), "The host refused.")
        let refused = await message(task)
        XCTAssertEqual(refused, "The host refused.")

        link.reply = nil
        task = try await ask()
        link.reply?(nil, nil)
        let missing = await message(task)
        XCTAssertEqual(missing, "Nothing came back.")

        link.reply = nil
        task = try await ask()
        link.reply?(Data("not json".utf8), nil)
        do { _ = try await task.value; XCTFail("An unreadable reply must fail") } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertEqual(link.invalidations, 3)
    }

    func testLostConnectionReportsTheHostsReasonUnlessOneIsGiven() async throws {
        var task = try await ask()
        link.onFailure?("Agent runtime was interrupted.")
        let reason = await message(task)
        XCTAssertEqual(reason, "Agent runtime was interrupted.")

        link.reply = nil
        task = try await ask(disconnected: "Could not inspect the harness version.")
        link.onFailure?("Agent runtime was interrupted.")
        let fixed = await message(task)
        XCTAssertEqual(fixed, "Could not inspect the harness version.")
    }

    func testTimeoutFailsAndALateReplyIsIgnored() async throws {
        let task = try await ask()
        timers[0].resolve(.success(()))
        let timedOut = await message(task)
        XCTAssertEqual(timedOut, "Took too long.")
        link.reply?(try JSONEncoder().encode(HostAnswer(name: "late")), nil)
        link.onFailure?("Agent runtime disconnected.")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(link.invalidations, 1)
    }

    func testCancellationEndsTheRequestAndClosesTheConnection() async throws {
        let task = try await ask()
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled request must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(link.invalidations, 1)
    }
}
