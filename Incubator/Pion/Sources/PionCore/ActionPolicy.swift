import Foundation

/// What each action an agent proposes may do, decided here in code and never by a model.
/// The operator edits it in Settings; agents cannot read or change it except through its verdicts.
public struct ActionPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Read-only, or reversible and in scope.
        case automatic
        /// Low impact and reversible, but visible: allowed, and the champion is told.
        case notify
        /// Containment, destructive or hard to undo: the champion decides.
        case approval
        /// Never allowed.
        case never

        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .notify: "Automatic, Then Notify"
            case .approval: "Needs Approval"
            case .never: "Never"
            }
        }
    }

    public struct Rule: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        /// An operation name such as isolate_host, or a prefix ending in `*` such as enrich_*.
        public var operation: String
        public var mode: Mode
        public init(id: UUID = UUID(), operation: String, mode: Mode) {
            self.id = id; self.operation = operation; self.mode = mode
        }

        func matches(_ operation: String) -> Bool {
            let pattern = self.operation.lowercased(), name = operation.lowercased()
            return pattern.hasSuffix("*") ? name.hasPrefix(String(pattern.dropLast())) : pattern == name
        }
    }

    public var rules: [Rule]
    /// Assets nothing may act on, whatever the scope says, such as domain controllers.
    public var protectedAssets: [String]
    /// The mode of an operation no rule names.
    public var fallback: Mode

    public init(rules: [Rule], protectedAssets: [String], fallback: Mode = .approval) {
        self.rules = rules; self.protectedAssets = protectedAssets; self.fallback = fallback
    }

    public static let standard = ActionPolicy(rules: [
        Rule(operation: "enrich_*", mode: .automatic),
        Rule(operation: "tag_*", mode: .automatic),
        Rule(operation: "snapshot_host", mode: .automatic),
        Rule(operation: "add_to_watchlist", mode: .automatic),
        Rule(operation: "reset_password", mode: .notify),
        Rule(operation: "revoke_sessions", mode: .notify),
        Rule(operation: "isolate_host", mode: .approval),
        Rule(operation: "disable_user", mode: .approval),
        Rule(operation: "revoke_oauth_app", mode: .approval),
        Rule(operation: "block_indicator", mode: .approval),
        Rule(operation: "kill_process", mode: .approval),
        Rule(operation: "quarantine_file", mode: .approval),
        Rule(operation: "delete_*", mode: .never),
        Rule(operation: "wipe_host", mode: .never),
    ], protectedAssets: [])

    public struct Verdict: Equatable, Sendable {
        public let mode: Mode
        /// Why, in a sentence an agent and the champion can both read.
        public let reason: String
    }

    /// The first matching rule decides, then the fallback. A target outside the scope or a
    /// protected asset makes it Never, whatever the rules say.
    public func verdict(operation: String, targets: [String], in investigation: Investigation) -> Verdict {
        if investigation.isClosed {
            return Verdict(mode: .never, reason: "\(investigation.reference) is closed.")
        }
        if targets.isEmpty {
            return Verdict(mode: .never, reason: "The action names no target.")
        }
        if let outside = targets.first(where: { !investigation.covers($0) }) {
            return Verdict(mode: .never, reason: "\(outside) is outside the scope of \(investigation.reference). Only its champion can widen the scope.")
        }
        if let protected = targets.first(where: isProtected) {
            return Verdict(mode: .never, reason: "\(protected) is a protected asset.")
        }
        if let rule = rules.first(where: { $0.matches(operation) }) {
            return Verdict(mode: rule.mode, reason: "The policy for \(rule.operation) is \(rule.mode.title.lowercased()).")
        }
        return Verdict(mode: fallback, reason: "No rule names \(operation), so it is \(fallback.title.lowercased()).")
    }

    public func isProtected(_ target: String) -> Bool {
        protectedAssets.contains { $0.caseInsensitiveCompare(target.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}
