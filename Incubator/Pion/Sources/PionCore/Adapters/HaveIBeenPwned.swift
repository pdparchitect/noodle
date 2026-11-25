import Foundation
import NoodleCore
import NoodleToolConnections

/// Have I Been Pwned: the data breaches and pastes an email address appears in, with the person's API key.
/// check-access reads the key's subscription, which searches nothing.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum HaveIBeenPwned {
    public static let preset = ToolDefinition(
        id: "d9a6dd05-60ea-4301-ba6c-bf3f1d3e8799", name: "Have I Been Pwned", summary: "The data breaches and pastes an email address appears in.",
        defaultInstructions: """
        Use Have I Been Pwned to see whether an email address appears in known data breaches or pastes, which breaches, \
        when, and what was exposed, such as passwords. A breach explains how credentials may have leaked; it does not show \
        they were used. Record each lookup as evidence, and keep the address to what the investigation needs. When a \
        lookup is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "haveibeenpwned",
        configuration: .connection(.init(endpoint: URL(string: "https://haveibeenpwned.com/api/v3")!, tokenHeader: "hibp-api-key",
                                  adapter: "haveibeenpwned")),
        setup: setup)

    static let setup = [
        "Buy an API key at [haveibeenpwned.com/API/Key](https://haveibeenpwned.com/API/Key); searching breaches and pastes by email needs one.",
        "Copy the key from your Have I Been Pwned dashboard and paste it here. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Breaches(), Pastes(), CheckAccess()])
}

extension HaveIBeenPwned {
    struct Breaches: ServiceOperation {
        struct Input: Decodable, Sendable { let email: String }
        static let name = "breaches"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The data breaches an email address appears in, when each happened and what it exposed."
        static let input = JSONSchema.object(["email": .string("The email address.")], required: ["email"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let email = try ServiceInput.email(input.email)
            struct Breach: Codable { let Name: String?, Title: String?, Domain: String?, BreachDate: String?, DataClasses: [String]?, IsVerified: Bool? }
            struct Breaches: Encodable { let breaches: [Breach] }
            let breaches: [Breach]
            do { breaches = try await service.get(["breachedaccount", email], query: ["truncateResponse": "false"], as: [Breach].self) }
            catch ServiceError.notFound { return try ServiceResult(text: "\(email) is not in any known breach.", structured: Breaches(breaches: [])) }
            let text = "\(email) is in \(breaches.count) breach\(breaches.count == 1 ? "" : "es"):\n" + breaches.map { breach in
                "\(breach.BreachDate ?? "?") \(breach.Title ?? breach.Name ?? "?")\(breach.Domain.map { " (\($0))" } ?? "")\(breach.IsVerified == false ? ", unverified" : ""): "
                    + (breach.DataClasses ?? []).joined(separator: ", ")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Breaches(breaches: breaches))
        }
    }

    struct Pastes: ServiceOperation {
        struct Input: Decodable, Sendable { let email: String }
        static let name = "pastes"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The pastes an email address appears in, newest first."
        static let input = JSONSchema.object(["email": .string("The email address.")], required: ["email"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let email = try ServiceInput.email(input.email)
            struct Paste: Codable { let Source: String?, Id: String?, Title: String?, Date: String?, EmailCount: Int? }
            struct Pastes: Encodable { let pastes: [Paste] }
            let pastes: [Paste]
            do { pastes = try await service.get(["pasteaccount", email], as: [Paste].self) }
            catch ServiceError.notFound { return try ServiceResult(text: "\(email) is in no known pastes.", structured: Pastes(pastes: [])) }
            let text = "\(email) is in \(pastes.count) paste\(pastes.count == 1 ? "" : "s"):\n"
                + pastes.prefix(20).map { "\($0.Date ?? "?") \($0.Source ?? "?") \($0.Title ?? $0.Id ?? "")" }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Pastes(pastes: pastes))
        }
    }
}

extension HaveIBeenPwned {
    static let fixes = AccessCheck.Fixes(
        rejected: "Have I Been Pwned did not accept the key: it is wrong, or its subscription has ended. Renew it at haveibeenpwned.com/API/Key and enter the key again in Settings › Tools.",
        forbidden: "Have I Been Pwned refused the key for this: its subscription may not include it.",
        rateLimited: "the subscription's requests a minute are used up: wait a minute, or choose a larger subscription.")

    /// Reads the key's subscription: its name, until when it runs and how many requests a minute it allows.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the key once with a read of its subscription, which searches nothing, and says the subscription, until when it runs and how many requests a minute it allows, or what to change."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(HaveIBeenPwned.fixes)
            struct Status: Decodable { let SubscriptionName: String?; let SubscribedUntil: String?; let Rpm: Int? }
            await check.probe("API key") {
                let status = try await service.get(["subscription", "status"], as: Status.self)
                var found = "the \(status.SubscriptionName ?? "?") subscription"
                if let until = status.SubscribedUntil { found += ", until \(until.prefix(10))" }
                if let rpm = status.Rpm { found += ", \(rpm) requests a minute" }
                return found
            }
            return try check.result()
        }
    }
}
