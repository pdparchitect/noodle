import Foundation

/// One plan limit of a subscription, such as a 5-hour session or a week, as the harness last reported it.
public struct SubscriptionUsageWindow: Codable, Hashable, Sendable, Identifiable {
    /// The harness's own name for the window, so a later report replaces it.
    public var id: String
    public var minutes: Int?
    /// The model a window is limited to, when it counts only one.
    public var model: String?
    /// Nil when the harness named the window without saying how much of it is used.
    public var usedPercent: Double?
    public var resetsAt: Date?

    public init(id: String, minutes: Int?, model: String? = nil, usedPercent: Double?, resetsAt: Date?) {
        self.id = id
        self.minutes = minutes
        self.model = model
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// The latest plan limits one signed-in account reported. Only what the harness
/// sent is kept; nothing is estimated from tokens or time.
public struct SubscriptionUsage: Codable, Hashable, Sendable {
    public var windows: [SubscriptionUsageWindow]
    public var updatedAt: Date

    public init(windows: [SubscriptionUsageWindow], updatedAt: Date) {
        self.windows = windows.sorted { ($0.minutes ?? .max, $0.model ?? "", $0.id) < ($1.minutes ?? .max, $1.model ?? "", $1.id) }
        self.updatedAt = updatedAt
    }

    /// Windows still running at `date`. Once a window resets, its old reading says nothing about the new one.
    public func current(at date: Date) -> [SubscriptionUsageWindow] {
        windows.filter { ($0.resetsAt ?? .distantFuture) > date }
    }

    /// Whether `provider` reports plan limits at all, so Settings shows them only for its accounts.
    public static func isReported(by provider: HarnessProvider) -> Bool {
        provider == .codex || provider == .claudeCode
    }

    /// Whether a runtime message carries plan limits for `provider`.
    public static func isReport(_ message: [String: Any], provider: HarnessProvider) -> Bool {
        switch provider {
        case .claudeCode: message["type"] as? String == "rate_limit_event"
        case .codex: message["method"] as? String == "account/rateLimits/updated"
        default: false
        }
    }

    /// The account's usage after a runtime message, or nil when the message changes nothing.
    public static func reading(_ message: [String: Any], provider: HarnessProvider,
                               previous: SubscriptionUsage?, at date: Date) -> SubscriptionUsage? {
        switch provider {
        case .claudeCode: return claude(message, previous: previous, at: date)
        case .codex:
            guard message["method"] as? String == "account/rateLimits/updated",
                  let snapshot = (message["params"] as? [String: Any])?["rateLimits"] as? [String: Any],
                  isDefaultCodexBucket(snapshot) else { return nil }
            return codex(snapshot, at: date)
        default: return nil
        }
    }

    // MARK: - Codex

    /// A Codex app-server `RateLimitSnapshot`, from `account/rateLimits/read` or
    /// `account/rateLimits/updated`: `primary` and `secondary` windows, each with
    /// `usedPercent` (0-100), `windowDurationMins` and `resetsAt` (Unix seconds).
    public static func codex(_ snapshot: [String: Any], at date: Date) -> SubscriptionUsage? {
        let windows = ["primary", "secondary"].compactMap { key -> SubscriptionUsageWindow? in
            guard let window = snapshot[key] as? [String: Any],
                  let used = number(window["usedPercent"]) else { return nil }
            return SubscriptionUsageWindow(id: key, minutes: number(window["windowDurationMins"]).map { Int($0) },
                                           usedPercent: used, resetsAt: number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:)))
        }
        return windows.isEmpty ? nil : SubscriptionUsage(windows: windows, updatedAt: date)
    }

    /// The `account/rateLimits/read` result. Its `rateLimits` is the account's
    /// main bucket, the one Codex itself shows; other buckets are left out.
    public static func codexRead(_ result: [String: Any], at date: Date) -> SubscriptionUsage? {
        let snapshot = (result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
            ?? result["rateLimits"] as? [String: Any]
        return snapshot.flatMap { codex($0, at: date) }
    }

    /// Updates for other buckets, such as one model's own limit, would replace the main one.
    private static func isDefaultCodexBucket(_ snapshot: [String: Any]) -> Bool {
        guard let id = snapshot["limitId"] as? String else { return true }
        return id == "codex"
    }

    // MARK: - Claude Code

    private static let claudeWindows: [String: (minutes: Int, model: String?)] = [
        "five_hour": (300, nil), "seven_day": (10_080, nil),
        "seven_day_opus": (10_080, "Opus"), "seven_day_sonnet": (10_080, "Sonnet")
    ]

    /// Claude Code's `rate_limit_event`. Its `rate_limit_info` names the window
    /// that limits the account now (`rateLimitType`), with `utilization` as a
    /// fraction and `resetsAt` in Unix seconds; when present, `unifiedWindows`
    /// carries the session and weekly windows together in the same units. One
    /// event may carry one window, so it is merged into what was reported before.
    public static func claude(_ event: [String: Any], previous: SubscriptionUsage?, at date: Date) -> SubscriptionUsage? {
        guard event["type"] as? String == "rate_limit_event",
              let info = event["rate_limit_info"] as? [String: Any] else { return nil }
        var reported: [SubscriptionUsageWindow] = []
        if let unified = info["unifiedWindows"] as? [String: Any] {
            for (key, value) in unified {
                guard let shape = claudeWindows[key], let window = value as? [String: Any],
                      let utilization = number(window["utilization"]) else { continue }
                reported.append(SubscriptionUsageWindow(id: key, minutes: shape.minutes, model: shape.model,
                    usedPercent: utilization * 100, resetsAt: number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:))))
            }
        }
        if let key = info["rateLimitType"] as? String, let shape = claudeWindows[key],
           !reported.contains(where: { $0.id == key }) {
            let resetsAt = number(info["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            var used = number(info["utilization"]).map { $0 * 100 }
            // A reading without utilization keeps the last one, but only for the same window.
            if used == nil, let earlier = previous?.windows.first(where: { $0.id == key }),
               earlier.resetsAt == resetsAt { used = earlier.usedPercent }
            if used != nil || resetsAt != nil {
                reported.append(SubscriptionUsageWindow(id: key, minutes: shape.minutes, model: shape.model,
                                                        usedPercent: used, resetsAt: resetsAt))
            }
        }
        guard !reported.isEmpty else { return nil }
        let kept = (previous?.windows ?? []).filter { old in !reported.contains { $0.id == old.id } }
        return SubscriptionUsage(windows: kept + reported, updatedAt: date)
    }

    private static func number(_ value: Any?) -> Double? {
        #if canImport(Darwin)
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        #else
        // Linux's JSON booleans are numbers of type `c`; its ints are `i` and `q`.
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        #endif
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

/// The words Settings shows for a plan limit.
public enum SubscriptionUsageFormat {
    public static let notAvailable = "Not available"

    public static func title(_ window: SubscriptionUsageWindow) -> String {
        let length: String
        switch window.minutes {
        case nil: length = "Limit"
        case 10_080: length = "Weekly limit"
        case 1_440: length = "Daily limit"
        case let minutes? where minutes > 0 && minutes % 1_440 == 0: length = "\(minutes / 1_440)-day limit"
        case let minutes? where minutes > 0 && minutes % 60 == 0: length = "\(minutes / 60)-hour limit"
        case let minutes?: length = "\(minutes)-minute limit"
        }
        return window.model.map { "\(length) · \($0)" } ?? length
    }

    /// The share of the limit used, from 0 to 1 for a bar; nil when not reported.
    public static func fraction(_ window: SubscriptionUsageWindow) -> Double? {
        window.usedPercent.map { min(max($0 / 100, 0), 1) }
    }

    public static func used(_ window: SubscriptionUsageWindow) -> String {
        guard let percent = window.usedPercent else { return notAvailable }
        // A window can run a little past its cap; the bound only keeps a bad reading from overflowing Int.
        return "\(Int(min(max(percent, 0), 999).rounded()))% used"
    }

    /// "Resets in 2 h 14 min" within a day, then the weekday and time, as "Resets Mon 09:00".
    public static func reset(_ window: SubscriptionUsageWindow, now: Date, calendar: Calendar = .current,
                             locale: Locale = .current) -> String? {
        guard let date = window.resetsAt, date > now else { return nil }
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "Resets in \(minutes) min" }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "Resets in \(minutes / 60) h" : "Resets in \(minutes / 60) h \(rest) min"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return "Resets \(formatter.string(from: date))"
    }

    /// One line for a window: how much is used and when it resets.
    public static func detail(_ window: SubscriptionUsageWindow, now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        [used(window), reset(window, now: now, calendar: calendar, locale: locale)].compactMap { $0 }.joined(separator: " · ")
    }
}
