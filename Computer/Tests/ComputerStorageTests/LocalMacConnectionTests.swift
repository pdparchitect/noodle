import Foundation
import LocalMacCore
import ComputerCore
import XCTest
@testable import NoodleComputer

/// Exercise the real client transport against a bounded pipe peer. These tests
/// never register services, log into accounts or request desktop permissions.
@MainActor final class LocalMacConnectionTests: XCTestCase {
    private func peer(_ input: Pipe, _ output: Pipe, count: Int,
                      respond: @escaping (LocalMacRequest) throws -> LocalMacReply) -> Task<[LocalMacRequest], Error> {
        Task.detached {
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var requests: [LocalMacRequest] = []
            for _ in 0..<count {
                let data = try XCTUnwrap(LocalMacWire.read(input.fileHandleForReading))
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); requests.append(request)
                let reply = try respond(request)
                try LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return requests
        }
    }
    private nonisolated static func reply(_ request: LocalMacRequest, displayID: UInt32? = nil) -> LocalMacReply {
        var reply = LocalMacReply(id: request.id)
        var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
        status.displayID = displayID; reply.status = status
        return reply
    }
    func testHandshakePrecedesCaptureAndTerminalRoundTrip() async throws {
        let input = Pipe(), output = Pipe()
        let terminal = UUID()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
            if request.operation == .terminalRead { reply.terminalID = terminal; reply.data = Data("workspace % ".utf8); reply.offset = 12 }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        var read = LocalMacRequest(.terminalRead); read.terminalID = terminal
        let reply = try await runtime.call(read)
        XCTAssertEqual(reply.terminalID, terminal)
        XCTAssertEqual(String(data: reply.data!, encoding: .utf8), "workspace % ")
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .terminalRead])
        XCTAssertEqual(requests[1].protectedDisplayIDs, [2])
        runtime.close()
    }
    func testOldHelperProducesActionableStartupFailure() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 1) { request in
            var reply = Self.reply(request); reply.protocolVersion = nil; return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        do {
            try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
            XCTFail("An unversioned helper must not start capture.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incompatible")) }
        XCTAssertFalse(runtime.isConnected)
        let requests = try await helper.value
        XCTAssertEqual(requests.count, 1)
    }
    func testMainDisplayAppearingStopsCaptureOnStatusPoll() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { Self.reply($0, displayID: 99) }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        displays.insert(99)
        await runtime.refreshStatus()
        XCTAssertFalse(runtime.isConnected)
        XCTAssertTrue(runtime.error?.contains("separate") == true)
        _ = try await helper.value
    }
    func testExpectedDisconnectDoesNotShowAnError() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request)
            if request.operation == .terminalRead { reply.id = nil; reply.error = "Desktop ended" }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        var unexpected = false; runtime.onDisconnect = { _ in unexpected = true }
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        runtime.expectDisconnect(true)
        var read = LocalMacRequest(.terminalRead); read.terminalID = UUID()
        do { _ = try await runtime.call(read); XCTFail("Disconnected request must fail.") } catch {}
        XCTAssertFalse(unexpected); XCTAssertNil(runtime.error); XCTAssertFalse(runtime.isConnected)
        _ = try await helper.value
    }
    func testSessionIgnoresOldConnectionsAndExpectedStops() {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let previous = LocalMacComputer(), current = LocalMacComputer()
        session.localMac = current; session.phase = .running
        session.localMacDisconnected(previous, reason: "stale")
        XCTAssertEqual(session.phase, .running)
        session.phase = .stopping
        session.localMacDisconnected(current, reason: "normal shutdown")
        XCTAssertEqual(session.phase, .stopping)
        session.phase = .running
        session.localMacDisconnected(current, reason: "lost")
        XCTAssertEqual(session.phase, .failed("lost"))
        session.phase = .starting
        session.localMacDisconnected(current, reason: "startup lost")
        XCTAssertEqual(session.phase, .failed("startup lost"))
    }
}
