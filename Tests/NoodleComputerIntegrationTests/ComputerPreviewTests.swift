import AppKit
import ComputerBridge
import SwiftTerm
import WebKit
import XCTest
@testable import Noodle

@MainActor final class PreviewPollClock {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func sleep(_ duration: Duration) async throws {
        calls += 1
        await withCheckedContinuation { pending.append($0) }
        try Task.checkCancellation()
    }
    func tick() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func finish() { let waiters = pending; pending.removeAll(); waiters.forEach { $0.resume() } }
}

@MainActor final class ComputerPreviewTests: XCTestCase {
    private func fixture() async throws -> ComputerLifecycleFixture {
        _ = NSApplication.shared
        let f = try ComputerLifecycleFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        try await f.prepare(); return f
    }
    private func terminal(_ f: ComputerLifecycleFixture, clock: PreviewPollClock) -> ComputerPreviewTerminal {
        let terminal = ComputerPreviewTerminal(card: f.card, controller: f.controller, sleep: clock.sleep)
        addTeardownBlock { @MainActor in terminal.stop(); clock.finish() }
        terminal.start(); return terminal
    }
    private func output(_ terminal: ComputerPreviewTerminal) -> String {
        String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
    }
    private func send(_ text: String, to terminal: ComputerPreviewTerminal) {
        terminal.send(source: terminal.view, data: Array(text.utf8)[...])
    }

    func testTerminalPollsFromConfirmedOffsetAndDrainsExitOutput() async throws {
        let f = try await fixture(), clock = PreviewPollClock()
        f.provider.responses[.terminalRead] = .init(data: Data("first".utf8), offset: 17, truncated: true)
        let t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        XCTAssertTrue(output(t).contains("Earlier output is no longer retained"))
        XCTAssertTrue(output(t).contains("first"))
        f.provider.responses[.terminalRead] = .init(data: Data("last".utf8), offset: 21, exited: true)
        clock.tick(); try await f.wait { clock.calls == 2 }
        f.provider.responses[.terminalRead] = .init(data: Data(), offset: 21, exited: true)
        clock.tick(); await t.reader?.value
        XCTAssertEqual(f.provider.requests.filter { $0.operation == .terminalRead }.compactMap(\.offset), [0, 17, 21])
        XCTAssertTrue(output(t).contains("last")); XCTAssertTrue(t.status.stringValue.contains("exited"))
        send("ignored", to: t); t.stop(); await t.writer?.value
        XCTAssertEqual(f.provider.count(.terminalWrite), 0)
    }

    func testTerminalWritesRemainOrderedAndUncertainInputIsNeverReplayed() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.blockedOperation = .terminalWrite
        send("first", to: t)
        try await f.wait { f.provider.blocked != nil }
        send("second", to: t)
        XCTAssertEqual(f.provider.count(.terminalWrite), 1)
        f.provider.blocked?.finish(.failure(ComputerBridgeError("Uncertain write")))
        await t.writer?.value
        XCTAssertTrue(t.status.stringValue.contains("Input was not retried"))
        send("third", to: t)
        XCTAssertEqual(f.provider.count(.terminalWrite), 1)
    }

    func testCancelledReadCannotOverwriteUncertainWriteError() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.blockedOperation = .terminalRead
        clock.tick(); try await f.wait { f.provider.blocked != nil }
        f.provider.errorOperation = .terminalWrite
        send("command", to: t); await t.writer?.value
        f.provider.blocked?.finish(.failure(ComputerBridgeError("Late read error")))
        await t.reader?.value
        XCTAssertTrue(t.status.stringValue.contains("Input was not retried"), t.status.stringValue)
    }

    func testClosingTerminalDiscardsLateReadAndQueuedInputWithoutClosingShell() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.blockedOperation = .terminalWrite
        send("first", to: t); try await f.wait { f.provider.blocked != nil }
        send("second", to: t)
        let before = output(t)
        t.stop(); clock.finish()
        f.provider.blocked?.finish(.success(f.provider.response(.terminalWrite)))
        await t.reader?.value; await t.writer?.value
        XCTAssertEqual(f.provider.count(.terminalWrite), 1)
        XCTAssertEqual(f.provider.count(.revoke), 0)
        XCTAssertEqual(output(t), before)
    }

    func testExitedTerminalDiscardsInputQueuedBehindInFlightWrite() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.blockedOperation = .terminalWrite
        send("first", to: t); try await f.wait { f.provider.blocked != nil }
        send("second", to: t)
        f.provider.responses[.terminalRead] = .init(data: Data(), exited: true)
        clock.tick(); await t.reader?.value
        f.provider.blocked?.finish(.success(f.provider.response(.terminalWrite)))
        try await f.wait { t.pendingBytes == 0 }
        t.stop(); await t.writer?.value
        XCTAssertEqual(f.provider.count(.terminalWrite), 1)
    }

    func testRevocationBlocksQueuedInputAndClearsTerminalReadAccess() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 }
        f.provider.blockedOperation = .list
        send("pending", to: t); try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.list)))
        await t.writer?.value
        XCTAssertEqual(f.provider.count(.terminalWrite), 0)
        XCTAssertTrue(t.status.stringValue.contains("revoked"))
    }

    func testResizeClampsDimensionsAndSuppressesDuplicates() async throws {
        let f = try await fixture(), clock = PreviewPollClock(), t = terminal(f, clock: clock)
        try await f.wait { clock.calls == 1 && f.provider.count(.terminalResize) == 1 }
        t.sizeChanged(source: t.view, newCols: 900, newRows: 0)
        t.sizeChanged(source: t.view, newCols: 999, newRows: -20)
        try await f.wait { f.provider.count(.terminalResize) == 2 }
        t.stop(); clock.finish(); await t.writer?.value
        let resize = try XCTUnwrap(f.provider.requests.last { $0.operation == .terminalResize })
        XCTAssertEqual(resize.columns, 500); XCTAssertEqual(resize.rows, 1)
    }

    func testPreviewReusesSameCardAndIgnoresCloseFromRetiredPanel() async throws {
        let f = try await fixture()
        let suite = "noodle-preview-test-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = ComputerPreviewController(defaults: defaults), card = f.card
        preview.show(card, controller: f.controller, present: false)
        let first = try XCTUnwrap(preview.panel)
        preview.show(card, controller: f.controller, present: false)
        XCTAssertTrue(preview.panel === first)
        let other = ComputerCard(computer: f.provider.computer, agentID: f.a.id, terminalID: UUID(), terminalPreview: "")
        preview.show(other, controller: f.controller, present: false)
        let second = try XCTUnwrap(preview.panel)
        defer { second.close(); preview.close() }
        XCTAssertFalse(second === first)
        preview.windowWillClose(.init(name: NSWindow.willCloseNotification, object: first))
        XCTAssertTrue(preview.panel === second)
        XCTAssertNotNil(preview.connection)
    }
}
