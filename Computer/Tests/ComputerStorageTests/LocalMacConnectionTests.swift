import AppKit
import ComputerBridge
import Foundation
import Combine
import LocalMacCore
import ComputerCore
import Surface
import XCTest
@testable import NoodleComputer

/// Exercise the real client transport against a bounded pipe peer. These tests
/// never register services, log into accounts or request desktop permissions.
@MainActor final class LocalMacConnectionTests: XCTestCase {
    private func peer(_ input: Pipe, _ output: Pipe, count: Int,
                      respond: @escaping (LocalMacRequest) async throws -> LocalMacReply) -> Task<[LocalMacRequest], Error> {
        Task.detached {
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var requests: [LocalMacRequest] = []
            for _ in 0..<count {
                let data = try XCTUnwrap(LocalMacWire.read(input.fileHandleForReading))
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); requests.append(request)
                let reply = try await respond(request)
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
    /// A desktop sends up to 60 frames a second. Every frame shown stayed in memory until the
    /// computer stopped, and a Local Mac left open for 17 hours held 41 GB of them.
    func testFramesAreFreedOnceANewerOneIsShown() async throws {
        let connection = try LocalMacTestDesktop()
        let streaming = expectation(description: "capture started")
        let helper = Task.detached { () throws -> Void in
            defer { connection.close() }
            while let request = try connection.read() {
                var reply = LocalMacReply(id: request.id)
                var status = LocalMacStatus(screenCapture: true, accessibility: true, postEvents: true, display: .init())
                status.displayID = 99; reply.status = status
                try connection.send(reply)
                if request.operation == .stream { streaming.fulfill() }
            }
        }
        let runtime = LocalMacComputer(displayIDs: { [2] }, presentsWindows: false)
        try await connection.connect(runtime, protectedDisplays: [2])
        await fulfillment(of: [streaming], timeout: 10)
        final class Shown { weak var image: NSImage? }
        var shown: [Shown] = []
        let watch = runtime.$image.compactMap { $0 }.sink { image in
            let entry = Shown(); entry.image = image; shown.append(entry)
        }
        func allocated() -> Int {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            return statistics.size_in_use
        }
        // The helper drops a frame while both of its slots are with the app, so this sends until
        // enough have been shown.
        func show(_ count: Int) async throws {
            let target = shown.count + count
            for attempt in 0..<5_000 where shown.count < target {
                try connection.sendFrame([UInt8(attempt % 256), 0, 0, 255], width: 1280, height: 800)
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertGreaterThanOrEqual(shown.count, target)
        }
        try await show(5)
        let before = allocated()
        try await show(50)
        let grown = allocated() - before
        watch.cancel()
        XCTAssertEqual(shown.dropLast().filter { $0.image != nil }.count, 0, "frames replaced by newer ones")
        // 50 frames of 1280 × 800 are 200 MB; a few may still be on their way to the screen.
        XCTAssertLessThan(grown, 10 * 1280 * 800 * 4, "bytes still allocated after 50 frames")
        runtime.close()
        try await helper.value
    }
    func testMissingPermissionKeepsConnectionUsableAndDefersCaptureUntilGranted() async throws {
        let input = Pipe(), output = Pipe()
        var granted = false
        let helper = peer(input, output, count: 4) { request in
            var reply = Self.reply(request)
            reply.status?.accessibility = granted
            reply.status?.postEvents = granted
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertFalse(runtime.status?.canControl ?? true)
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.isConnected)
        granted = true
        await runtime.refreshStatus()
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .status, .status, .stream])
        XCTAssertEqual(requests.last?.protectedDisplayIDs, [2])
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
    /// A capture that failed in the helper left the desktop on its error with nothing to press,
    /// and polling never asked again; only Stop and Start brought it back.
    func testFailedCaptureCanBeTriedAgain() async throws {
        let input = Pipe(), output = Pipe()
        var failing = true
        let helper = peer(input, output, count: 4) { request in
            var reply = Self.reply(request, displayID: failing ? nil : 99)
            if failing { reply.status?.detail = "The user declined TCCs" }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        XCTAssertTrue(runtime.canRetryCapture)
        await runtime.refreshStatus()
        failing = false
        await runtime.retryCapture()
        XCTAssertFalse(runtime.canRetryCapture)
        runtime.close()
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .status, .stream])
        XCTAssertEqual(requests.last?.protectedDisplayIDs, [2])
    }

    /// Answers until the client closes, for requests the client sends by itself.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LocalMacRequest] = []
        func append(_ request: LocalMacRequest) { lock.lock(); values.append(request); lock.unlock() }
        var requests: [LocalMacRequest] { lock.lock(); defer { lock.unlock() }; return values }
        var streams: [LocalMacRequest] { requests.filter { $0.operation == .stream } }
    }
    private func openPeer(_ input: Pipe, _ output: Pipe, log: RequestLog,
                          respond: @escaping (LocalMacRequest) -> LocalMacReply) -> Task<Void, Error> {
        Task.detached {
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            while let data = try LocalMacWire.read(input.fileHandleForReading) {
                let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
                try request.validate(); log.append(request)
                try LocalMacWire.write(JSONEncoder().encode(respond(request)), to: output.fileHandleForWriting)
            }
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out")
    }
    func testLockedMacStartsWithoutCaptureUntilItsDisplaysReturn() async throws {
        let input = Pipe(), output = Pipe(), log = RequestLog()
        let helper = openPeer(input, output, log: log) { Self.reply($0, displayID: $0.operation == .stream ? 99 : nil) }
        var displays: Set<UInt32> = []
        let runtime = LocalMacComputer(displayIDs: { displays })
        var disconnects: [String] = []; runtime.onDisconnect = { disconnects.append($0) }
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertEqual(log.requests.map(\.operation), [.status])
        // No view polls here: capture must come back on its own.
        displays = [2]
        try await waitUntil { !log.streams.isEmpty }
        XCTAssertEqual(log.streams.map(\.enabled), [true])
        XCTAssertEqual(log.streams.first?.protectedDisplayIDs, [2])
        XCTAssertTrue(disconnects.isEmpty)
        runtime.close()
        try await helper.value
    }
    func testLockingTheMacPausesCaptureAndKeepsTheConnection() async throws {
        let desktop = try LocalMacTestDesktop(), log = RequestLog()
        let helper = Task.detached {
            var streaming = false
            while let request = try desktop.read() {
                log.append(request)
                if request.operation == .stream { streaming = request.enabled == true }
                try desktop.send(Self.reply(request, displayID: streaming ? 99 : nil))
                if streaming { try desktop.sendFrame([0xff, 0x80, 0x10, 0xff]) }
            }
        }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        var disconnects: [String] = []; runtime.onDisconnect = { disconnects.append($0) }
        try await desktop.connect(runtime, protectedDisplays: [2])
        try await waitUntil { runtime.image != nil }
        XCTAssertEqual(LocalMacTestDesktop.color(runtime.image), [0xff, 0x80, 0x10, 0xff], "Pictures arrive unchanged.")

        displays = []
        await runtime.refreshStatus()
        XCTAssertNil(runtime.image, "Frames must not be shown while the main desktop's displays are unknown.")
        try await waitUntil { log.streams.count == 2 && runtime.status?.displayID == nil }
        XCTAssertEqual(log.streams.map(\.enabled), [true, false])
        XCTAssertTrue(runtime.isConnected)
        XCTAssertNil(runtime.error)
        XCTAssertNil(runtime.image)
        var read = LocalMacRequest(.terminalRead); read.terminalID = UUID()
        _ = try await runtime.call(read)

        displays = [2]
        try await waitUntil { log.streams.count == 3 && runtime.image != nil }
        XCTAssertEqual(log.streams.map(\.enabled), [true, false, true])
        XCTAssertEqual(log.streams.last?.protectedDisplayIDs, [2])
        XCTAssertTrue(disconnects.isEmpty)
        runtime.close()
        try await helper.value
    }
    func testInputIsSentWithoutWaitingForEachReply() async throws {
        let desktop = try LocalMacTestDesktop(), held = expectation(description: "three keys arrive before any is answered")
        let helper = Task.detached { () throws -> [UInt16] in
            var inputs: [LocalMacRequest] = []
            while let request = try desktop.read() {
                guard request.operation == .input else { try desktop.send(Self.reply(request, displayID: 99)); continue }
                inputs.append(request)
                if inputs.count == 3 {
                    held.fulfill()
                    for input in inputs { try desktop.send(LocalMacReply(id: input.id)) }
                }
            }
            return inputs.compactMap { $0.input?.key }
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        try await desktop.connect(runtime, protectedDisplays: [2])
        for key in [1, 2, 3] as [UInt16] { var event = LocalMacInput(.keyDown); event.key = key; runtime.send(event) }
        await fulfillment(of: [held], timeout: 10)
        _ = try await runtime.call(.init(.status))
        XCTAssertNil(runtime.error)
        runtime.close()
        let keys = try await helper.value
        XCTAssertEqual(keys, [1, 2, 3], "Input keeps its order.")
    }
    func testMainDisplayCaptureStillDisconnectsWhileTheMacIsLocked() async throws {
        let input = Pipe(), output = Pipe()
        var replies = 0
        let helper = peer(input, output, count: 3) { request in
            replies += 1
            return Self.reply(request, displayID: ([nil, 99, 2] as [UInt32?])[replies - 1])
        }
        var displays: Set<UInt32> = [2]
        let runtime = LocalMacComputer(displayIDs: { displays })
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        displays = []
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
    func testPermissionErrorClearsOnlyWhenAccessibilityAndEventPostingRecover() async throws {
        let input = Pipe(), output = Pipe()
        var replyNumber = 0
        let helper = peer(input, output, count: 5) { request in
            replyNumber += 1
            var reply = Self.reply(request, displayID: 99)
            reply.status?.accessibility = replyNumber >= 3
            reply.status?.postEvents = replyNumber >= 4
            if request.operation == .input { reply.status = nil; reply.error = LocalMacStatus.inputPermissionError }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        let failed = expectation(description: "Input denial received")
        let observer = runtime.$error.sink { if $0 == LocalMacStatus.inputPermissionError { failed.fulfill() } }
        runtime.send(LocalMacInput(.move))
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.status?.accessibility == true)
        XCTAssertFalse(runtime.status?.canControl == true)
        XCTAssertEqual(runtime.error, LocalMacStatus.inputPermissionError)
        await runtime.refreshStatus()
        XCTAssertTrue(runtime.status?.canControl == true)
        XCTAssertNil(runtime.error)
        _ = try await helper.value
        runtime.close()
    }
    func testPermissionRecoveryPreservesAnUnrelatedFailure() async throws {
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 4) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .input { reply.status = nil; reply.error = LocalMacStatus.inputPermissionError }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        let failed = expectation(description: "Input denial received")
        let observer = runtime.$error.sink { if $0 == LocalMacStatus.inputPermissionError { failed.fulfill() } }
        runtime.send(LocalMacInput(.move))
        await fulfillment(of: [failed], timeout: 2)
        observer.cancel()
        runtime.error = "A separate capture failure"
        await runtime.refreshStatus()
        XCTAssertEqual(runtime.error, "A separate capture failure")
        _ = try await helper.value
        runtime.close()
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

    func testRestartReplacesTerminalAndFileConnections() async throws {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let previous = LocalMacComputer()
        session.localMac = previous
        let terminal = GuestTerminal()
        let connection = LocalMacTerminalConnection(runtime: previous, terminal: terminal)
        connection.id = UUID()
        session.localTerminal = connection; session.terminal = terminal
        let oldFiles = session.filesModel(for: previous)
        oldFiles.error = "The desktop connection is unavailable or busy."
        session.phase = .failed("Desktop capture stopped")

        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .fileHome { reply.homeDirectory = "/Users/retained" }
            return reply
        }
        let current = LocalMacComputer(displayIDs: { [2] })
        current.expectDisconnect(true)
        try await current.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = current; session.phase = .running
        defer { current.close() }

        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertNil(connection.id)
        let files = session.filesModel(for: current)
        XCTAssertFalse(files === oldFiles)
        XCTAssertNil(files.error)
        let home = try await files.service.homeDirectory()
        XCTAssertEqual(home, "/Users/retained")
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .fileHome])
    }

    func testSameConnectionPreservesSurfacesAndRemovalClosesThem() {
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let runtime = LocalMacComputer()
        session.localMac = runtime
        let terminal = GuestTerminal()
        let connection = LocalMacTerminalConnection(runtime: runtime, terminal: terminal)
        connection.id = UUID()
        session.localTerminal = connection; session.terminal = terminal
        let files = session.filesModel(for: runtime)
        files.folder = "/workspace/Documents"

        session.localMac = runtime
        XCTAssertTrue(session.localTerminal === connection)
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertTrue(session.filesModel(for: runtime) === files)
        XCTAssertEqual(files.folder, "/workspace/Documents")
        XCTAssertNotNil(connection.id)

        session.localMac = nil
        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertNil(connection.id)
    }

    func testTerminalOpeningCannotRestoreAnOldConnectionAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        let replacement = LocalMacComputer()
        let input = Pipe(), output = Pipe()
        let helper = peer(input, output, count: 3) { request in
            var reply = Self.reply(request, displayID: 99)
            if request.operation == .terminalOpen {
                await MainActor.run { session.localMac = replacement }
                reply.terminalID = UUID()
            }
            return reply
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        defer { runtime.close() }
        session.localMac = runtime; session.phase = .running

        await store.selectDisplay(.terminal, in: session)

        XCTAssertTrue(session.localMac === replacement)
        XCTAssertNil(session.localTerminal)
        XCTAssertNil(session.terminal)
        XCTAssertEqual(session.displayMode, .desktop)
        XCTAssertFalse(session.openingTerminal)
        XCTAssertNil(store.error)
        let requests = try await helper.value
        XCTAssertEqual(requests.map(\.operation), [.status, .stream, .terminalOpen])
    }

    /// Agents share a Local Mac's 16 running shells; the person's own terminal never counts.
    /// Opened from the Hub, as from Noodle on iPhone, a Local Mac shows its desktop and takes taps
    /// and typing. It used to refuse with a terminal error, which the viewer showed as
    /// "The Hub could not show this."
    func testHubLiveViewShowsTheDesktopAndTakesInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let session = ComputerSession(Computer(name: "Theo", kind: .localMac))
        store.sessions = [session]
        let input = Pipe(), output = Pipe()
        let received = expectation(description: "input reached the helper")
        received.expectedFulfillmentCount = 3
        let helper = Task.detached { () -> [LocalMacInput] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var inputs: [LocalMacInput] = []
            while let data = try? LocalMacWire.read(input.fileHandleForReading),
                  let request = try? LocalMacWire.decode(LocalMacRequest.self, from: data) {
                if request.operation == .input, let event = request.input { inputs.append(event); received.fulfill() }
                let reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
                try? LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return inputs
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = runtime; session.phase = .running
        runtime.image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let companion = SurfaceSocket(fd: fds[0]), viewer = SurfaceSocket(fd: fds[1])
        defer { companion.close(); viewer.close() }

        _ = try await provider.handle(.init(.surfaceStream, computerID: session.id, agentID: UUID()), peer: "hub", surface: companion)
        let pictured = expectation(description: "the viewer got a picture")
        pictured.assertForOverFulfill = false
        let watching = Task { for await frame in viewer.frames where !(SurfacePacket.decode(frame) ?? []).isEmpty { pictured.fulfill() } }
        defer { watching.cancel() }
        viewer.send(SurfaceControl.input(.pointer(.down, x: 400, y: 150)).encoded)
        viewer.send(SurfaceControl.input(.pointer(.up, x: 400, y: 150)).encoded)
        viewer.send(SurfaceControl.input(.text("hi")).encoded)
        await fulfillment(of: [received, pictured], timeout: 10)

        runtime.close()
        let inputs = await helper.value
        XCTAssertEqual(inputs.map(\.kind), [.down, .up, .text])
        XCTAssertEqual(inputs[0].x, 0.5, accuracy: 0.01)
        XCTAssertEqual(inputs[0].y, 0.25, accuracy: 0.01)
        XCTAssertEqual(inputs[2].text, "hi")
    }
    func testAgentShellsAreLimitedButThePersonsTerminalAlwaysOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        store.sessions = [session]
        let ids = (0..<20).map { _ in UUID() }
        let input = Pipe(), output = Pipe()
        // Serves until the app disconnects; the first agent's shell has ended.
        let helper = Task.detached { () -> [LocalMacOperation] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var operations: [LocalMacOperation] = [], opened = 0
            while let data = try? LocalMacWire.read(input.fileHandleForReading),
                  let request = try? LocalMacWire.decode(LocalMacRequest.self, from: data) {
                operations.append(request.operation)
                var reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
                if request.operation == .terminalOpen { reply.terminalID = ids[opened]; opened += 1 }
                if request.operation == .terminalRead {
                    reply.terminalID = request.terminalID; reply.offset = 0; reply.exited = request.terminalID == ids[0]
                }
                try? LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return operations
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = runtime; session.phase = .running
        let agents = (0..<18).map { _ in UUID() }
        func open(_ agent: UUID) async throws -> UUID? {
            try await provider.handle(.init(.terminalOpen, computerID: session.id, agentID: agent), peer: "agents").terminalID
        }

        for agent in agents[0..<16] { _ = try await open(agent) }
        do { _ = try await open(agents[16]); XCTFail("A 17th agent shell opened") } catch {}
        await store.selectDisplay(.terminal, in: session)
        XCTAssertNotNil(session.localTerminal)
        XCTAssertNil(store.error)
        let read = try await provider.handle(.init(.terminalRead, computerID: session.id, agentID: agents[0], terminalID: ids[0]), peer: "agents")
        XCTAssertEqual(read.exited, true)
        let replacement = try await open(agents[17])
        XCTAssertEqual(replacement, ids[17])

        session.localTerminal?.close()
        runtime.close()
        let operations = await helper.value
        XCTAssertEqual(operations.filter { $0 == .terminalOpen }.count, 18)
    }

    /// Bots that lost their shells cannot close them. A shell idle at its prompt that no call has used
    /// for half an hour is closed for them; one running a command stays however long it runs, and
    /// one whose helper cannot tell stays six hours. Each bot lists only its own.
    func testAgentShellsLeftIdleAtThePromptAreClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let provider = try ComputerProvider(store: store, socket: root.appendingPathComponent("computer.sock"), listens: false)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var clock = start
        provider.now = { clock }
        let session = ComputerSession(Computer(name: "Retained", kind: .localMac))
        store.sessions = [session]
        let ids = (0..<20).map { _ in UUID() }
        let building = ids[1], olderHelper = ids[2], used = ids[3]
        let input = Pipe(), output = Pipe()
        let helper = Task.detached { () -> [UUID] in
            defer { try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
            var closed: [UUID] = [], opened = 0
            while let data = try? LocalMacWire.read(input.fileHandleForReading),
                  let request = try? LocalMacWire.decode(LocalMacRequest.self, from: data) {
                var reply = Self.reply(request, displayID: request.operation == .status ? nil : 99)
                switch request.operation {
                case .terminalOpen: reply.terminalID = ids[opened]; opened += 1
                case .terminalRead:
                    reply.terminalID = request.terminalID; reply.offset = 0; reply.exited = false
                    reply.running = request.terminalID == olderHelper ? nil : request.terminalID == building
                case .terminalClose: closed += request.terminalID.map { [$0] } ?? []
                default: break
                }
                try? LocalMacWire.write(JSONEncoder().encode(reply), to: output.fileHandleForWriting)
            }
            return closed
        }
        let runtime = LocalMacComputer(displayIDs: { [2] })
        runtime.expectDisconnect(true)
        try await runtime.connect(input: output.fileHandleForReading, output: input.fileHandleForWriting, protectedDisplays: [2])
        session.localMac = runtime; session.phase = .running
        let agents = (0..<18).map { _ in UUID() }
        func open(_ agent: UUID) async throws -> UUID? {
            try await provider.handle(.init(.terminalOpen, computerID: session.id, agentID: agent), peer: "agents").terminalID
        }
        func terminals(_ agent: UUID) async throws -> [RemoteTerminal] {
            try await provider.handle(.init(.terminalList, computerID: session.id, agentID: agent), peer: "agents").terminals ?? []
        }

        for agent in agents[0..<16] { _ = try await open(agent) }
        clock += 20 * 60
        _ = try await provider.handle(.init(.terminalWrite, computerID: session.id, agentID: agents[3], terminalID: used, data: Data("ls\r".utf8)), peer: "agents")
        clock += 11 * 60
        let replacement = try await open(agents[16])
        XCTAssertEqual(replacement, ids[16], "idle shells made room")
        let listed = try await terminals(agents[1])
        XCTAssertEqual(listed, [RemoteTerminal(id: building, opened: start, used: start, running: true, exited: false)], "listing and checking are not use")
        let unsure = try await terminals(agents[2]), recent = try await terminals(agents[3]), idle = try await terminals(agents[0])
        XCTAssertEqual(unsure.map(\.id), [olderHelper])
        XCTAssertNil(unsure.first?.running)
        XCTAssertEqual(recent.map(\.used), [start + 20 * 60])
        XCTAssertEqual(idle, [], "idle at its prompt for 31 minutes")

        clock += 6 * 60 * 60
        _ = try await open(agents[17])
        let unsureLater = try await terminals(agents[2]), stillBuilding = try await terminals(agents[1])
        XCTAssertEqual(unsureLater, [], "kept six hours where the helper cannot tell")
        XCTAssertEqual(stillBuilding.map(\.id), [building], "a command still running keeps its shell")

        runtime.close()
        let closed = await helper.value
        XCTAssertEqual(Set(closed), Set(ids[0...16]).subtracting([building]))
    }
}

/// The desktop helper's end of a real connection: one socket, with pictures sent through shared
/// memory the way the helper sends them. Slots the app hands back are freed here.
final class LocalMacTestDesktop: @unchecked Sendable {
    let app: FileHandle, helper: FileHandle
    private let frames = LocalMacFrameWriter()
    private let lock = NSLock()
    init() throws { (helper, app) = try LocalMacWire.socketPair() }
    func connect(_ runtime: LocalMacComputer, protectedDisplays: Set<UInt32>) async throws {
        try await runtime.connect(input: app, output: app, protectedDisplays: protectedDisplays)
    }
    /// The next request other than a slot handed back; nil once the app has closed.
    func read() throws -> LocalMacRequest? {
        while let data = try LocalMacWire.read(helper) {
            let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
            try request.validate()
            guard request.operation == .frameRelease else { return request }
            lock.withLock { frames.release(request.frame!) }
        }
        return nil
    }
    func send(_ reply: LocalMacReply) throws { try LocalMacWire.write(JSONEncoder().encode(reply), to: helper) }
    /// A frame of one BGRA colour; window frames belong to their preview's stream.
    func sendFrame(_ bgra: [UInt8], width: Int = 20, height: Int = 10, window: LocalMacWindowFrame? = nil) throws {
        let written = try lock.withLock {
            try frames.write(stream: window?.previewID, width: width, height: height) { memory, bytesPerRow in
                for row in 0..<height { for column in 0..<width {
                    (memory + row * bytesPerRow + column * 4).copyMemory(from: bgra, byteCount: 4)
                } }
            }
        }
        // Like the helper, drop the frame while both of the stream's slots are with the app.
        guard let frame = written else { return }
        if let (region, descriptor) = frame.region {
            defer { Darwin.close(descriptor) }
            var announcement = LocalMacReply(); announcement.region = region
            try LocalMacWire.write(JSONEncoder().encode(announcement), to: helper, descriptor: descriptor)
        }
        var reply = LocalMacReply(); reply.frame = true; reply.sharedFrame = frame.frame; reply.windowFrame = window
        try send(reply)
    }
    func close() { Darwin.shutdown(helper.fileDescriptor, SHUT_RDWR); try? helper.close() }
    /// The colour of an image's first pixel, as BGRA.
    static func color(_ image: NSImage?) -> [UInt8]? {
        guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = picture.dataProvider?.data as Data? else { return nil }
        return Array(data.prefix(4))
    }
}
