import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeShutdownTests: XCTestCase {
    func testEachHarnessRetainsItsConnectionUntilStopIsConfirmed() async throws {
        for provider in [HarnessProvider.codex, .claudeCode, .apple, .fx, .grokBuild] {
            let f = try HarnessRuntimeFixture()
            addTeardownBlock { @MainActor in f.cleanUp() }
            let wire = HarnessWire()
            wire.automaticStop = false
            let process: any AgentRuntimeProcess
            switch provider {
            case .codex: process = f.codex(wire)
            case .claudeCode: process = f.claude(wire)
            default: process = f.acp(wire, provider: provider)
            }
            process.start()
            await f.drain()
            var results: [Bool] = []
            process.stop { results.append($0) }
            process.stop { results.append($0) }
            XCTAssertEqual(wire.stopCalls, 1, "Concurrent stops must share confirmation: \(provider)")
            let firstReply = try XCTUnwrap(wire.stopReply)
            firstReply(false)
            await f.drain()
            XCTAssertEqual(results, [false, false])
            process.start()
            XCTAssertEqual(wire.launches.count, 1, "An unconfirmed stop must block another start")
            process.stop { results.append($0) }
            XCTAssertEqual(wire.stopCalls, 2, "Retry must reach the same helper: \(provider)")
            firstReply(true)
            await f.drain()
            XCTAssertEqual(results, [false, false], "A stale reply cannot confirm the current attempt")
            wire.stopReply?(true)
            await f.drain()
            XCTAssertEqual(results, [false, false, true])
            process.stop { results.append($0) }
            XCTAssertEqual(wire.stopCalls, 2, "Confirmed stops need no more helper calls")
            XCTAssertEqual(results, [false, false, true, true])
        }
    }

    func testMuseAlsoRetriesTheOriginalConnection() async throws {
        let f = try MuseRuntimeFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let (process, wire) = f.make()
        wire.automaticStop = false
        process.start()
        try await f.waitUntil { process.canReceiveHeartbeat }
        var results: [Bool] = []
        process.stop { results.append($0) }
        wire.stopReply?(false)
        try await f.waitUntil { results == [false] }
        process.stop { results.append($0) }
        XCTAssertEqual(wire.stops, 2)
        wire.stopReply?(true)
        try await f.waitUntil { results == [false, true] }
    }
}
