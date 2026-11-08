import Foundation

/// The time line over a message that starts a new stretch of talk, as Messages shows it: the first message,
/// the first of a day, and any after an hour's quiet.
public enum TranscriptTimestamp {
    public static let quietSpell: TimeInterval = 3_600

    public static func caption(
        for date: Date, after previous: Date?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        if let previous, calendar.isDate(date, inSameDayAs: previous), date.timeIntervalSince(previous) < quietSpell {
            return nil
        }
        return text(for: date, now: now, calendar: calendar, locale: locale)
    }

    /// "Today 09:05", "Yesterday 05:55", the weekday within the last week, then the date, with the year only when it differs.
    public static func text(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let day = switch days {
        case 0: "Today"
        case 1: "Yesterday"
        case 2..<7: date.formatted(style.weekday(.wide))
        default: calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
            : date.formatted(style.day().month(.abbreviated).year())
        }
        return "\(day) \(time)"
    }
}
