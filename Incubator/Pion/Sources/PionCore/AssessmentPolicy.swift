import Foundation

/// What an organisation says it allows, which an Assessment's checks hold its services to. Every answer is optional:
/// a check whose answer is missing says so and does not run, as no check assumes one.
///
/// It is kept as Markdown: front matter between two `---` lines, one `key: value` per line, then the person's own
/// prose, which is kept as written.
public struct AssessmentPolicy: Codable, Equatable, Sendable {
    public enum Devices: String, Codable, CaseIterable, Sendable {
        case companyOnly = "company-only", personalAllowed = "personal-allowed"
    }

    public enum ExternalSharing: String, Codable, CaseIterable, Sendable {
        case allowed, notAllowed = "not-allowed"
    }

    public enum TwoStepVerification: String, Codable, CaseIterable, Sendable {
        case required, optional
    }

    public var devices: Devices?
    public var externalSharing: ExternalSharing?
    public var twoStepVerification: TwoStepVerification?
    public var maxSuperAdmins: Int?
    public var inactiveAccountDays: Int?
    public var staleDeviceDays: Int?
    /// OAuth client IDs the organisation has approved; an empty list approves none.
    public var approvedApps: [String]?

    private enum CodingKeys: String, CodingKey {
        case devices, externalSharing = "external-sharing", twoStepVerification = "two-step-verification",
             maxSuperAdmins = "max-super-admins", inactiveAccountDays = "inactive-account-days",
             staleDeviceDays = "stale-device-days", approvedApps = "approved-apps"
    }

    public init(devices: Devices? = nil, externalSharing: ExternalSharing? = nil, twoStepVerification: TwoStepVerification? = nil,
                maxSuperAdmins: Int? = nil, inactiveAccountDays: Int? = nil, staleDeviceDays: Int? = nil, approvedApps: [String]? = nil) {
        self.devices = devices
        self.externalSharing = externalSharing
        self.twoStepVerification = twoStepVerification
        self.maxSuperAdmins = maxSuperAdmins
        self.inactiveAccountDays = inactiveAccountDays
        self.staleDeviceDays = staleDeviceDays
        self.approvedApps = approvedApps
    }

    /// What the questionnaire starts from, for the person to change. Checks never fall back on it.
    public static let defaults = AssessmentPolicy(devices: .companyOnly, externalSharing: .notAllowed, twoStepVerification: .required,
                                                  maxSuperAdmins: 3, inactiveAccountDays: 90, staleDeviceDays: 90, approvedApps: [])

    /// Every key, in the order the front matter is written.
    public static let keys = ["devices", "external-sharing", "two-step-verification", "max-super-admins",
                              "inactive-account-days", "stale-device-days", "approved-apps"]

    /// An answer as the front matter writes it, or nil when it is unanswered.
    public func value(forKey key: String) -> String? {
        switch key {
        case "devices": devices?.rawValue
        case "external-sharing": externalSharing?.rawValue
        case "two-step-verification": twoStepVerification?.rawValue
        case "max-super-admins": maxSuperAdmins.map(String.init)
        case "inactive-account-days": inactiveAccountDays.map(String.init)
        case "stale-device-days": staleDeviceDays.map(String.init)
        case "approved-apps": approvedApps.map { "[" + $0.joined(separator: ", ") + "]" }
        default: nil
        }
    }

    /// The answer `value` gives, or a missing answer as the policy saying nothing about `question`, such as "whether
    /// 2-step verification is required".
    public func required<Value>(_ value: Value?, _ question: String) throws -> Value {
        guard let value else { throw AssessmentCheckError.policyMissing(question) }
        return value
    }

    /// The answers that differ from `earlier`, as written.
    public func changes(from earlier: AssessmentPolicy) -> [(key: String, from: String?, to: String?)] {
        Self.keys.compactMap { key in
            let before = earlier.value(forKey: key), now = value(forKey: key)
            return before == now ? nil : (key, before, now)
        }
    }

    // MARK: Markdown

    /// Reads the front matter, ignoring comments and keys it does not know; a value it cannot read stays unanswered.
    public init(markdown: String) {
        self.init()
        guard let (front, _) = Self.split(markdown) else { return }
        var listing: String?
        for line in front {
            let trimmed = Self.uncommented(line)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if listing == "approved-apps" {
                    let item = Self.unquoted(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    if !item.isEmpty { approvedApps = (approvedApps ?? []) + [item] }
                }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { listing = nil; continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Self.unquoted(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            listing = value.isEmpty ? key : nil
            set(key, value)
        }
    }

    private mutating func set(_ key: String, _ value: String) {
        func count(_ least: Int) -> Int? { Int(value).flatMap { $0 >= least ? $0 : nil } }
        switch key {
        case "devices": devices = Devices(rawValue: value.lowercased())
        case "external-sharing": externalSharing = ExternalSharing(rawValue: value.lowercased())
        case "two-step-verification": twoStepVerification = TwoStepVerification(rawValue: value.lowercased())
        case "max-super-admins": maxSuperAdmins = count(1)
        case "inactive-account-days": inactiveAccountDays = count(1)
        case "stale-device-days": staleDeviceDays = count(1)
        case "approved-apps":
            // A list on one line, bracketed or not; an empty value starts one written as "- " lines below it.
            var list = value
            if list.hasPrefix("[") && list.hasSuffix("]") { list = String(list.dropFirst().dropLast()) }
            else if list.hasPrefix("[") || list.hasSuffix("]") { approvedApps = nil; return }
            approvedApps = list.split(separator: ",").map { Self.unquoted($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        default: break
        }
    }

    /// The prose after the front matter, or all of `markdown` when it has none.
    public static func body(of markdown: String) -> String {
        split(markdown)?.body ?? markdown
    }

    /// The answers as front matter, then `body`.
    public func markdown(body: String) -> String {
        let lines = Self.keys.compactMap { key in value(forKey: key).map { "\(key): \($0)" } }
        let front = (["---"] + lines + ["---"]).joined(separator: "\n") + "\n"
        let body = body.drop { $0 == "\n" }
        return body.isEmpty ? front : front + "\n" + body
    }

    /// The answers as front matter, keeping the prose of `existing`, a policy written before.
    public func markdown(keepingBody existing: String?) -> String {
        markdown(body: existing.map(Self.body(of:)) ?? "")
    }

    /// The front matter's lines and the prose after it, or nil when it does not open with front matter.
    private static func split(_ markdown: String) -> (front: [String], body: String)? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[open].trimmingCharacters(in: .whitespaces) == "---",
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let body = lines[(close + 1)...].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        return (Array(lines[(open + 1)..<close]), body)
    }

    /// A line without its comment: one from a # at its start, or from a # after a space.
    private static func uncommented(_ line: String) -> String {
        var line = line
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return "" }
        if let comment = line.range(of: " #") { line = String(line[..<comment.lowerBound]) }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
