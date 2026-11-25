import Foundation

/// The checks an Assessment of Google Workspace runs, in the order its checklist shows them. Each reads only through
/// Google Workspace Detection's read-only operations for audit.
public enum GoogleWorkspaceChecks {
    static let source = "Google Workspace"

    public static let all: [AssessmentCheck] = [twoStepEnrolment, unverifiedDomains]

    /// Every account, as many as users lists at once; an answer that holds that many may have had more.
    static let allUsers = CheckRead("users", ["limit": .number(10000)], items: "users")
    static let domains = CheckRead("domains", items: "domains")

    static let twoStepEnrolment = AssessmentCheck(
        id: "gws.2sv-enrolment", title: "Active accounts enrolled in 2-step verification", severity: .high,
        rationale: "Without 2-step verification, a password alone opens the account, and passwords are phished, guessed and reused often enough that one is never enough.",
        fix: "Ask each account listed to turn on 2-step verification, then enforce it in the Admin console under Security › Authentication › 2-step verification, with a short enrolment period for new accounts.",
        source: source, policyKeys: ["two-step-verification"],
        reads: { policy in
            try requiresTwoStep(policy) ? [allUsers] : []
        },
        evaluate: { inputs, policy in
            guard try requiresTwoStep(policy) else { return .pass("The policy makes 2-step verification optional.") }
            struct User: Decodable { let primaryEmail: String?, id: String?, isEnrolledIn2Sv: Bool?, suspended: Bool?, archived: Bool?, isGuestUser: Bool? }
            struct Listed: Decodable { let users: [User]? }
            // Suspended and archived accounts can't sign in, so they leave nothing open; guest accounts sign in with
            // their own Google account, whose 2-step verification the organisation doesn't set. Each is counted aside,
            // so the numbers add up to the Admin console's.
            let all = try inputs.decode(Listed.self, from: allUsers).users ?? []
            let suspended = all.filter { $0.suspended == true }.count
            let archived = all.filter { $0.suspended != true && $0.archived == true }.count
            let guests = all.filter { $0.suspended != true && $0.archived != true && $0.isGuestUser == true }.count
            let active = all.filter { $0.suspended != true && $0.archived != true && $0.isGuestUser != true }
            let aside = [(suspended, "suspended"), (archived, "archived"), (guests, "guest")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            let notCounted = aside.isEmpty ? "" : " Not counted: \(aside.joined(separator: ", ")) account\(suspended + archived + guests == 1 ? "" : "s")."
            let unenrolled = active.filter { $0.isEnrolledIn2Sv != true }.map { $0.primaryEmail ?? $0.id ?? "an account without an address" }
            guard !unenrolled.isEmpty else {
                return .pass("All \(active.count) active account\(active.count == 1 ? " is" : "s are") enrolled in 2-step verification." + notCounted)
            }
            return .fail("\(unenrolled.count) of \(active.count) active accounts \(unenrolled.count == 1 ? "isn't" : "aren't") enrolled in 2-step verification, which the policy requires." + notCounted,
                         offenders: unenrolled)
        })

    private static func requiresTwoStep(_ policy: AssessmentPolicy) throws -> Bool {
        try policy.required(policy.twoStepVerification, "whether 2-step verification is required") == .required
    }

    static let unverifiedDomains = AssessmentCheck(
        id: "gws.unverified-domains", title: "Every domain is verified", severity: .medium,
        rationale: "Google hasn't confirmed the organisation owns a domain that was added but never verified, so its mail and accounts don't work as intended; one left that way is often a typo or a domain the organisation no longer holds, which someone else could register.",
        fix: "In the Admin console under Account › Domains › Manage domains, verify each domain listed or remove it.",
        source: source,
        reads: { _ in [domains] },
        evaluate: { inputs, _ in
            struct Domain: Decodable { let name: String, verified: Bool? }
            struct Listed: Decodable { let domains: [Domain]? }
            let listed = try inputs.decode(Listed.self, from: domains).domains ?? []
            let unverified = listed.filter { $0.verified != true }.map(\.name)
            guard !unverified.isEmpty else {
                return .pass("All \(listed.count) domain\(listed.count == 1 ? " is" : "s and aliases are") verified.")
            }
            return .fail("\(unverified.count) of \(listed.count) domains and aliases \(unverified.count == 1 ? "isn't" : "aren't") verified.",
                         offenders: unverified)
        })
}
