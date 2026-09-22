import Foundation

/// Dates as bots write them, for every tool that takes one. ISO 8601 with a zone is an
/// exact moment; without one, the same wall clock this Mac shows; a plain date is a day.
public enum ToolDates {
    private static let zoned: [ISO8601DateFormatter] = {
        let exact = ISO8601DateFormatter(); exact.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [exact, fractional]
    }()
    private static let local: [(format: String, hasTime: Bool)] = [
        ("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true),
        ("yyyy-MM-dd HH:mm:ss", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)]

    /// The parsed moment, and whether the bot named a time of day at all.
    public static func parse(_ raw: String) -> (date: Date, hasTime: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let date = zoned.compactMap({ $0.date(from: trimmed) }).first { return (date, true) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for candidate in local {
            formatter.dateFormat = candidate.format
            if let date = formatter.date(from: trimmed) { return (date, candidate.hasTime) }
        }
        return nil
    }

    private static let output: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    /// A moment in this Mac's zone, or just the day when there is no time to show.
    public static func string(_ date: Date, hasTime: Bool = true) -> String {
        hasTime ? output.string(from: date) : String(output.string(from: date).prefix(10))
    }
}
