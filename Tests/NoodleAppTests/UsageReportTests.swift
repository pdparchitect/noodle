import Foundation
import XCTest
@testable import Noodle
@testable import NoodleCore

final class UsageReportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// Wednesday 24 September 2026, mid-afternoon.
    private let now = Date(timeIntervalSince1970: 1_790_258_400)

    private func day(_ offset: Int, _ name: String, tokens: Int, cost: Double? = nil,
                     harness: String = "claude-code", model: String = "claude-opus-5-5") -> UsageDay {
        UsageDay(day: calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!,
                 agentID: UUID(), agentName: name, harness: harness, model: model,
                 tokens: UsageTokens(input: tokens), costUSD: cost)
    }

    func testRangesEndTomorrowAndCoverWholeDaysOrMonths() {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertEqual(UsageReport.range(.week, now: now, calendar: calendar),
                       calendar.date(byAdding: .day, value: -6, to: today)!..<tomorrow)
        XCTAssertEqual(UsageReport.range(.month, now: now, calendar: calendar).lowerBound,
                       calendar.date(byAdding: .day, value: -29, to: today)!)
        XCTAssertEqual(UsageReport.range(.year, now: now, calendar: calendar).lowerBound,
                       calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!)
    }

    /// Today counts as one of the period's days.
    func testDailyAverageDividesByEveryDayInThePeriod() {
        let days = (0..<7).map { day($0, "Ada", tokens: 100, cost: 0.7) }
        let tokens = UsageReport(days: days, span: .week, grouping: .agent, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(tokens.dailyAverage, 100)
        let cost = UsageReport(days: days, span: .week, grouping: .agent, metric: .cost, now: now, calendar: calendar)
        XCTAssertEqual(cost.dailyAverage, 0.7, accuracy: 0.000_001)
    }

    func testSmallestGroupsFoldIntoOtherAndTiesAreOrderedByName() {
        var days = ["Hal", "Gus", "Fay", "Eve", "Dan", "Cy", "Bo"].map { day(0, $0, tokens: 100) }
        days += [day(0, "Zed", tokens: 1), day(1, "Ann", tokens: 1)]
        let report = UsageReport(days: days, span: .week, grouping: .agent, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(report.rows.map(\.group), ["Bo", "Cy", "Dan", "Eve", "Fay", "Gus", "Hal", "Ann", "Zed"])
        XCTAssertEqual(report.groups, ["Bo", "Cy", "Dan", "Eve", "Fay", "Gus", "Hal", UsageReport.otherGroup])
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(report.bars.filter { $0.group == UsageReport.otherGroup }.map(\.value), [1, 1])
        XCTAssertEqual(report.bars.filter { $0.bucket == today }.map(\.group), ["Bo", "Cy", "Dan", "Eve", "Fay", "Gus", "Hal", "Other"])
        XCTAssertEqual(report.share(of: report.rows[0])!, 100.0 / 702, accuracy: 0.000_001)
    }

    func testYearBucketsByMonthAndLabelsHarnessesAndModels() {
        let days = [day(0, "Ada", tokens: 10, cost: 0.5, harness: "codex", model: ""),
                    day(1, "Ada", tokens: 20, harness: "codex", model: ""),
                    day(40, "Ada", tokens: 5, harness: "grok-build", model: "grok-4.7")]
        let byHarness = UsageReport(days: days, span: .year, grouping: .harness, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(byHarness.groups, ["Codex", "Grok Build"])
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        XCTAssertEqual(byHarness.bars.first { $0.bucket == september }, .init(bucket: september, group: "Codex", value: 30))
        XCTAssertEqual(byHarness.rows.first { $0.group == "Grok Build" }?.cost, nil)
        XCTAssertEqual(byHarness.cost, 0.5)
        let byModel = UsageReport(days: days, span: .year, grouping: .model, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(byModel.groups, ["Default Model", "grok-4.7"])
    }

    func testBotsSharingANameStayApart() {
        var first = day(0, "Ada", tokens: 10), second = day(0, "Ada", tokens: 20), again = day(1, "Ada", tokens: 5)
        first.agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        again.agentID = first.agentID
        let report = UsageReport(days: [second, first, again], span: .week, grouping: .agent, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(report.rows.map(\.group), ["Ada (2)", "Ada"])
        XCTAssertEqual(report.rows.map(\.tokens.total), [20, 15])
    }

    func testCacheHitsAreTheShareOfInputReadFromTheCache() {
        var cached = day(0, "Ada", tokens: 20)
        cached.tokens = UsageTokens(input: 20, output: 500, cacheRead: 70, cacheWrite: 10)
        let report = UsageReport(days: [cached], span: .week, grouping: .agent, metric: .tokens, now: now, calendar: calendar)
        XCTAssertEqual(report.cacheHitRate, 0.7, accuracy: 0.000_001)
    }
}
