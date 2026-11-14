import Foundation
import NoodleCore
import NoodleMCP

/// Have I Been Pwned: the data breaches and pastes an email address appears in, with the person's API key.
public enum HaveIBeenPwned {
    public static let preset = ToolDefinition(
        id: "haveibeenpwned", name: "Have I Been Pwned", summary: "The data breaches and pastes an email address appears in.",
        defaultInstructions: """
        Use Have I Been Pwned to see whether an email address appears in known data breaches or pastes, which breaches, \
        when, and what was exposed, such as passwords. A breach explains how credentials may have leaked; it does not show \
        they were used. Record each lookup as evidence, and keep the address to what the investigation needs.
        """,
        iconName: "haveibeenpwned",
        configuration: .mcp(.init(endpoint: URL(string: "https://haveibeenpwned.com/api/v3")!, tokenHeader: "hibp-api-key",
                                  adapter: "haveibeenpwned")))

    public static let adapter = OperationAdapter(operations: [Breaches(), Pastes()])
}

extension HaveIBeenPwned {
    struct Breaches: ServiceOperation {
        struct Input: Decodable, Sendable { let email: String }
        static let name = "breaches"
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
