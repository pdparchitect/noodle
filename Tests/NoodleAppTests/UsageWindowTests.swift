import AppKit
import NoodleCore
@testable import NoodleRuntimeSettings
import SwiftUI
import XCTest
@testable import NoodleRuntime

@MainActor final class UsageWindowTests: XCTestCase {
    /// A closed Usage window stays alive for reopening, so it must not keep reading the ledger.
    func testClosedWindowStopsReadingTheLedgerUntilReopened() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let history = UsageHistory(url: folder.appendingPathComponent("usage.sqlite"))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UsageView(history: history, agents: []))
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        window.orderBack(nil)
        try await wait { history.queries > 0 }

        window.close()
        try await settle()
        let closed = history.queries
        for _ in 0..<3 {
            history.record(UsageSample(date: Date(), agentID: UUID(), agentName: "Alfred", harness: "codex",
                model: "gpt", tokens: UsageTokens(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0), costUSD: nil))
            try await settle()
        }
        XCTAssertEqual(history.queries, closed)

        window.orderBack(nil)
        try await wait { history.queries > closed }
    }

    /// A choice seen before shows again without reading or summing anything; another grouping or measure of the same
    /// period sums again without reading; new usage starts over.
    func testReportsAreKeptPerChoiceUntilNewUsage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let history = UsageHistory(url: folder.appendingPathComponent("usage.sqlite"))
        let sample = UsageSample(date: Date(), agentID: UUID(), agentName: "Alfred", harness: "codex", model: "gpt",
            tokens: UsageTokens(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0), costUSD: nil)
        history.record(sample)
        let reports = UsageReports()
        let tokens = UsageReports.Choice(span: .month, agentID: nil, grouping: .agent, metric: .tokens, user: nil)
        let byModel = UsageReports.Choice(span: .month, agentID: nil, grouping: .model, metric: .tokens, user: nil)

        await reports.show(tokens, history: history, people: UsagePeople())
        XCTAssertEqual(reports.shown?.choice, tokens)
        XCTAssertEqual(reports.shown?.report.tokens.total, 2)
        XCTAssertFalse(reports.waiting)
        XCTAssertEqual(history.queries, 1)

        await reports.show(byModel, history: history, people: UsagePeople())
        XCTAssertEqual(reports.shown?.choice, byModel)
        XCTAssertEqual(reports.shown?.report.rows.map(\.group), ["gpt"])
        XCTAssertEqual(history.queries, 1, "the same period was read again")
        XCTAssertEqual(reports.builds, 2)

        await reports.show(tokens, history: history, people: UsagePeople())
        XCTAssertEqual(reports.shown?.choice, tokens)
        XCTAssertEqual(history.queries, 1)
        XCTAssertEqual(reports.builds, 2, "a report seen before was summed again")

        history.record(sample)
        await reports.show(tokens, history: history, people: UsagePeople())
        XCTAssertEqual(reports.shown?.report.tokens.total, 4)
        XCTAssertEqual(history.queries, 2)
    }

    private func settle() async throws {
        for _ in 0..<20 {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
