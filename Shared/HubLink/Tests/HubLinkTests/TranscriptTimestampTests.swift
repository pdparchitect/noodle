import Foundation
import XCTest
@testable import HubLink

final class TranscriptTimestampTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        return calendar
    }
    /// Saturday 10 October 2026, 12:00.
    private var now: Date { date(2026, 10, 10, 12) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func caption(_ date: Date, after previous: Date?) -> String? {
        TranscriptTimestamp.caption(for: date, after: previous, now: now, calendar: calendar, locale: locale)
    }

    /// The first message says when the conversation began.
    func testTheFirstMessageHasACaption() {
        XCTAssertEqual(caption(date(2026, 10, 10, 9, 5), after: nil), "Today 09:05")
    }

    /// Messages close together read as one stretch of talk.
    func testAMessageSoonAfterTheLastHasNone() {
        XCTAssertNil(caption(date(2026, 10, 10, 9, 59), after: date(2026, 10, 10, 9, 5)))
    }

    /// An hour's quiet starts a new stretch, even on the same day.
    func testAnHoursQuietStartsANewStretch() {
        XCTAssertEqual(caption(date(2026, 10, 10, 10, 5), after: date(2026, 10, 10, 9, 5)), "Today 10:05")
    }

    /// A new day always gets a caption, however short the gap.
    func testANewDayAlwaysHasACaption() {
        XCTAssertEqual(caption(date(2026, 10, 10, 0, 1), after: date(2026, 10, 9, 23, 59)), "Today 00:01")
    }

    func testDaysReadAsMessagesSaysThem() {
        XCTAssertEqual(caption(date(2026, 10, 9, 5, 55), after: nil), "Yesterday 05:55")
        XCTAssertEqual(caption(date(2026, 10, 7, 13, 2), after: nil), "Wednesday 13:02")
        XCTAssertEqual(caption(date(2026, 10, 3, 8, 0), after: nil), "Sat 3 Oct 08:00")
        XCTAssertEqual(caption(date(2025, 12, 24, 18, 30), after: nil), "24 Dec 2025 18:30")
    }
}
