import Foundation
import XCTest
@testable import Noodle

final class SidebarTimestampTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func timestamp(_ date: Date) -> String {
        SidebarTimestamp.text(for: date, now: self.date(2026, 10, 10), calendar: calendar, locale: locale)
    }

    func testEarlierDayThisYearLeavesOutTheYear() {
        XCTAssertEqual(timestamp(date(2026, 9, 25)), "25 Sep")
    }

    func testEarlierYearKeepsTheYear() {
        XCTAssertEqual(timestamp(date(2025, 9, 25)), "25 Sep 2025")
    }

    func testTodayShowsTheTime() {
        XCTAssertEqual(timestamp(date(2026, 10, 10, 9)), "09:00")
    }
}
