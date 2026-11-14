import Foundation
import NoodleCore
import NoodleMCP

/// GitHub: an organisation's audit log, its people, and the secrets found in its code, read with a token.
/// Each account is one organisation.
public enum GitHub {
    public static let preset = ToolDefinition(
        id: "github-security", name: "GitHub", summary: "An organisation's audit log, members and outside collaborators, and secret scanning alerts.",
        defaultInstructions: """
        Use GitHub to see what happened in an organisation: search its audit log for who did what and when, such as \
        repo.destroy, org.add_member or protected_branch changes; list its members and outside collaborators; and list \
        secrets found in its code, with whether each is still valid. The audit log needs GitHub Enterprise Cloud. Record \
        each finding as evidence. These tools only read: recommend removing access or rotating a secret to the champion.
        """,
        iconName: "github",
        configuration: .mcp(.init(endpointTemplate: "https://api.github.com/orgs/{org}",
            fields: [ToolField(key: "org", title: "Organisation", placeholder: "kestrel-labs", kind: .identifier)],
            tokenHeader: "Authorization", adapter: "github")))

    public static let adapter = OperationAdapter(operations: [AuditLog(), People(), SecretAlerts()])
}

extension GitHub {
    struct AuditLog: ServiceOperation {
        struct Input: Decodable, Sendable { let phrase: String?, limit: Int? }
        static let name = "audit-log"
        static let summary = "The organisation's audit log, newest first, filtered by a search phrase such as actor:mallory action:repo.destroy created:>=2026-11-13."
        static let input = JSONSchema.object([
            "phrase": .string("An audit log search phrase, such as actor:mallory action:repo.destroy created:>=2026-11-13."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 events.") }
            var query: [String: String?] = ["include": "all", "order": "desc", "per_page": String(limit)]
            if let phrase = input.phrase?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty {
                guard phrase.count <= 300, !phrase.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ServiceError.input("Give the search phrase on one line.")
                }
                query["phrase"] = phrase
            }
            struct Location: Codable { let country_code: String? }
            struct Event: Decodable {
                enum Keys: String, CodingKey { case timestamp = "@timestamp", action, actor, actor_ip, user, repo, actor_location }
                let time: String?, action: String?, actor: String?, ip: String?, user: String?, repo: String?, country: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Keys.self)
                    let stamp = try? container.decodeIfPresent(Double.self, forKey: .timestamp)
                    time = stamp.flatMap { $0 }.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1_000)) }
                    action = try container.decodeIfPresent(String.self, forKey: .action)
                    actor = try container.decodeIfPresent(String.self, forKey: .actor)
                    ip = try container.decodeIfPresent(String.self, forKey: .actor_ip)
                    user = try container.decodeIfPresent(String.self, forKey: .user)
                    repo = try container.decodeIfPresent(String.self, forKey: .repo)
                    country = try container.decodeIfPresent(Location.self, forKey: .actor_location)?.country_code
                }
            }
            struct Kept: Encodable { let time: String?, action: String?, actor: String?, ip: String?, user: String?, repo: String?, country: String? }
            struct Events: Encodable { let events: [Kept] }
            let events = try await service.get(["audit-log"], query: query, as: [Event].self).map {
                Kept(time: $0.time, action: $0.action, actor: $0.actor, ip: $0.ip, user: $0.user, repo: $0.repo, country: $0.country)
            }
            let text = events.isEmpty ? "No audit log events match." : events.prefix(30).map { event in
                var line = "\(event.time ?? "?") \(event.action ?? "?")"
                if let actor = event.actor { line += " by \(actor)" }
                if let ip = event.ip { line += " from \(ip)" }
                if let country = event.country { line += " (\(country))" }
                if let repo = event.repo { line += " on \(repo)" }
                if let user = event.user { line += " affecting \(user)" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }

    struct People: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "people"
        static let summary = "The organisation's members and its outside collaborators."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Person: Codable { let login: String; let site_admin: Bool? }
            struct People: Encodable { let members: [Person]; let outsideCollaborators: [Person] }
            let members = try await service.get(["members"], query: ["per_page": "100"], as: [Person].self)
            let outside = try await service.get(["outside_collaborators"], query: ["per_page": "100"], as: [Person].self)
            let text = "\(members.count) member\(members.count == 1 ? "" : "s"): \(members.map(\.login).joined(separator: ", "))."
                + (outside.isEmpty ? " No outside collaborators." : " \(outside.count) outside collaborator\(outside.count == 1 ? "" : "s"): \(outside.map(\.login).joined(separator: ", ")).")
            return try ServiceResult(text: text, structured: People(members: members, outsideCollaborators: outside))
        }
    }

    struct SecretAlerts: ServiceOperation {
        struct Input: Decodable, Sendable { let state: String? }
        static let name = "secret-alerts"
        static let summary = "Secrets found in the organisation's code, with the repository and whether each is still valid."
        static let input = JSONSchema.object(["state": .string("Open or resolved alerts. Open when left out.", oneOf: ["open", "resolved"])])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let state = try ServiceInput.oneOf(input.state ?? "open", ["open", "resolved"], "state")
            struct Repository: Codable { let full_name: String? }
            struct Alert: Codable {
                let number: Int?, state: String?, secret_type_display_name: String?, created_at: String?, validity: String?
                let repository: Repository?, html_url: String?
            }
            struct Alerts: Encodable { let alerts: [Alert] }
            let alerts = try await service.get(["secret-scanning", "alerts"], query: ["state": state, "per_page": "50"], as: [Alert].self)
            let text = alerts.isEmpty ? "No \(state) secret scanning alerts." : alerts.map { alert in
                "\(alert.created_at ?? "?") \(alert.secret_type_display_name ?? "secret") in \(alert.repository?.full_name ?? "?")\(alert.validity.map { ", \($0)" } ?? "")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Alerts(alerts: alerts))
        }
    }
}
