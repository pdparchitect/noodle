import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class HarnessLifecycleTests: XCTestCase {
    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func make(_ provider: HarnessProvider, _ f: HarnessRuntimeFixture, _ wire: HarnessWire) -> any AgentRuntimeProcess {
        switch provider {
        case .codex: return f.codex(wire)
        case .claudeCode: return f.claude(wire)
        default: return f.acp(wire)
        }
    }
    private func open(_ provider: HarnessProvider, _ f: HarnessRuntimeFixture, _ wire: HarnessWire, resuming: Bool = false) async throws {
        switch provider {
        case .codex: try await f.openCodex(wire, resuming: resuming)
        case .claudeCode: try await f.wait { f.processes.last?.canReceiveHeartbeat == true }
        default: try await f.openACP(wire, resuming: resuming)
        }
    }

    func testStartupTimeoutReportsOnceAndRejectsLateAcknowledgement() async throws {
        for provider in [HarnessProvider.codex, .claudeCode, .fx] {
            let f = try fixture(), wire = HarnessWire(), p = make(provider, f, wire)
            wire.automaticStart = false; p.notify()
            let timer = try await f.clock.next(.seconds(60)); timer.resolve(.success(()))
            try await f.wait { p.snapshot.phase == .failed }
            wire.startReply?(555, nil); wire.onExit?(1); await f.drain()
            XCTAssertEqual(f.failures.count, 1)
            XCTAssertEqual(f.failures.first?.1, true)
            XCTAssertTrue(wire.writes.isEmpty)
            XCTAssertFalse(p.isAlive)
        }
    }

    func testUnacknowledgedInterruptPreservesRecoveryAndStopsTransport() async throws {
        for provider in [HarnessProvider.codex, .claudeCode, .fx] {
            let f = try fixture(), wire = HarnessWire(), p = make(provider, f, wire)
            p.start(); try await open(provider, f, wire); p.notify()
            if provider == .codex {
                try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]]); await f.drain()
            }
            p.notify(immediately: true)
            let timer = try await f.clock.next(.seconds(10)); timer.resolve(.success(()))
            try await f.wait { p.snapshot.phase == .failed }
            XCTAssertEqual(f.failures.count, 1)
            XCTAssertEqual(f.failures.first?.1, true)
            XCTAssertTrue(f.recovery(provider).hasUnfinishedTurn)
            XCTAssertEqual(wire.invalidations, 1)
        }
    }

    func testRetiredTransportCallbacksCannotAffectRestartedProcess() async throws {
        for provider in [HarnessProvider.codex, .claudeCode, .fx] {
            let f = try fixture(), old = HarnessWire(), p = make(provider, f, old)
            p.start(); try await open(provider, f, old)
            let oldExit = old.onExit, oldData = old.onData, oldStarted = old.startReply
            let stopped = await withCheckedContinuation { continuation in
                p.stop { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(stopped)
            let next = HarnessWire(); old.replacement = next
            p.start(); try await open(provider, f, next, resuming: provider != .claudeCode)
            oldExit?(3); oldStarted?(777, "Retired launch failed")
            oldData?(Data("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"wrong\"}\n".utf8), false)
            await f.drain()
            XCTAssertTrue(p.canReceiveHeartbeat)
            XCTAssertTrue(f.failures.isEmpty)
            XCTAssertEqual(next.invalidations, 0)
        }
    }

    func testCancelledStartupTimeoutCannotOverwriteStoppedState() async throws {
        for provider in [HarnessProvider.codex, .claudeCode, .fx] {
            let f = try fixture(), wire = HarnessWire(), p = make(provider, f, wire)
            wire.automaticStart = false; p.start()
            let timer = try await f.clock.next(.seconds(60))
            p.stop { _ in }; timer.resolve(.success(())); await f.drain()
            XCTAssertEqual(p.snapshot.phase, .offline)
            XCTAssertTrue(f.failures.isEmpty)
        }
    }
}
