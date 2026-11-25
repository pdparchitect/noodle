import Foundation
import NoodleCore
import NoodleToolConnections

/// GitHub: an organisation's audit log, its people, and its security alerts. Each account is one
/// organisation, read as the person who signs in through an OAuth app the organisation registered, with a code:
/// GitHub's browser sign-in needs the app's client secret, which a Mac app cannot keep, and its device sign-in does not.
public enum GitHub {
    public static let preset = ToolDefinition(
        id: "07d106a4-0e2c-47b1-a743-3c71161e56e4", name: "GitHub", summary: "An organisation's audit log, members and outside collaborators, and secret scanning, code scanning and Dependabot alerts.",
        defaultInstructions: """
        Use GitHub to see what happened in an organisation: search its audit log for who did what and when, such as \
        repo.destroy, org.add_member or protected_branch changes; list its members, which are owners, and its outside \
        collaborators; list its teams with their members, as teams carry access to repositories; and list \
        its open security alerts: secrets found in its code, with whether each is still valid, code scanning results and \
        vulnerable dependencies. The audit log needs GitHub Enterprise Cloud. Record each finding as evidence. These tools \
        only read: recommend removing access, rotating a secret or fixing code to the champion.
        """,
        iconName: "github",
        configuration: .connection(.init(endpointTemplate: "https://api.github.com/orgs/{org}",
            fields: [ToolField(key: "org", title: "Organisation", placeholder: "kestrel-labs", kind: .identifier),
                     ToolField(key: "clientID", title: "Client ID", placeholder: "Ov23liAbCdEfGhIjKlMn", kind: .identifier)],
            oauth: MCPOAuthConfiguration(issuer: URL(string: "https://github.com")!,
                authorizationEndpoint: URL(string: "https://github.com/login/oauth/authorize")!,
                tokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!, clients: [],
                scopes: ["read:org", "read:audit_log", "security_events"], usesResourceIndicator: false,
                deviceAuthorizationEndpoint: URL(string: "https://github.com/login/device/code")!),
            oauthClientField: "clientID", adapter: "github")),
        setup: setup)

    static let setup = [
        "On GitHub, open the organisation's **Settings › Developer settings › OAuth Apps** and choose **New OAuth App**.",
        "Name it, such as Pion, and give the organisation's own website as both its homepage and its callback URL; Pion does not use them.",
        "Tick **Enable Device Flow**, register the app and copy its **Client ID** here. It needs no client secret.",
        "Choose **Add & Connect**: Pion shows a code and opens GitHub, where you enter it and approve the app's access to read the organisation, its audit log and its security alerts.",
        "Sign in as an owner or security manager of the organisation, who can read its security alerts. The audit log needs GitHub Enterprise Cloud.",
    ]

    /// Paced, as teams asks for each team's members and GitHub limits requests at once.
    public static let adapter = OperationAdapter(operations: [AuditLog(), People(), Teams(), SecurityAlerts()], trigger: NewSecurityAlerts(),
                                                 simultaneousRequests: 8)
}

extension GitHub {
    struct AuditLog: ServiceOperation {
        struct Input: Decodable, Sendable { let phrase: String?, limit: Int? }
        static let name = "audit-log"
        static let jobs: Set<ToolJob> = [.detection]
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
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The organisation's members, which of them are owners, and its outside collaborators."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Person: Codable { let login: String; let site_admin: Bool? }
            struct People: Encodable { let members: [Person]; let owners: [String]; let outsideCollaborators: [Person] }
            let members = try await service.get(["members"], query: ["per_page": "100"], as: [Person].self)
            // Owners can do anything in the organisation, so an audit of who holds what starts with them.
            let owners = try await service.get(["members"], query: ["per_page": "100", "role": "admin"], as: [Person].self).map(\.login)
            let outside = try await service.get(["outside_collaborators"], query: ["per_page": "100"], as: [Person].self)
            let text = "\(members.count) member\(members.count == 1 ? "" : "s"): \(members.map(\.login).joined(separator: ", "))."
                + " \(owners.count) owner\(owners.count == 1 ? "" : "s"): \(owners.isEmpty ? "none listed" : owners.joined(separator: ", "))."
                + (outside.isEmpty ? " No outside collaborators." : " \(outside.count) outside collaborator\(outside.count == 1 ? "" : "s"): \(outside.map(\.login).joined(separator: ", ")).")
            return try ServiceResult(text: text, structured: People(members: members, owners: owners, outsideCollaborators: outside))
        }
    }

    /// The organisation's three feeds of security alerts, each across all its repositories, newest first.
    enum AlertKind: String, CaseIterable {
        case secret, code, dependency
        var path: [String] {
            switch self {
            case .secret: ["secret-scanning", "alerts"]
            case .code: ["code-scanning", "alerts"]
            case .dependency: ["dependabot", "alerts"]
            }
        }
        var title: String {
            switch self {
            case .secret: "Secret scanning"
            case .code: "Code scanning"
            case .dependency: "Dependabot"
            }
        }
    }

    struct SecurityAlert: Codable {
        struct Repository: Codable { let full_name: String? }
        struct Rule: Codable { let security_severity_level: String?; let description: String? }
        struct Advisory: Codable { let severity: String?; let summary: String? }
        struct Package: Codable { let name: String? }
        struct Dependency: Codable { let package: Package? }
        let number: Int?, created_at: String?, html_url: String?, repository: Repository?
        let secret_type_display_name: String?, validity: String?
        let rule: Rule?
        let security_advisory: Advisory?, dependency: Dependency?
    }

    /// The open alerts of one kind, newest first: a page of a hundred, which reaches back far enough between checks.
    static func openAlerts(_ kind: AlertKind, severity: String? = nil, on service: ServiceClient) async throws -> [SecurityAlert] {
        try await service.get(kind.path, query: ["state": "open", "severity": severity, "sort": "created", "direction": "desc", "per_page": "100"],
                              as: [SecurityAlert].self)
    }

    /// Reads each feed on its own, so one the organisation has not turned on, or the person cannot read, leaves the
    /// others; only when none answers does it fail.
    static func eachFeed<Item>(_ feeds: [(AlertKind, () async throws -> [Item])]) async throws -> (items: [Item], failures: [String]) {
        var items: [Item] = [], failures: [String] = [], first: Error?
        for (kind, read) in feeds {
            do { items += try await read() } catch {
                first = first ?? error
                failures.append("\(kind.title) could not be read: \(error.localizedDescription)")
            }
        }
        if failures.count == feeds.count, let first { throw first }
        return (items, failures)
    }

    struct SecurityAlerts: ServiceOperation {
        struct Input: Decodable, Sendable { let kind: String?, since: String? }
        static let name = "security-alerts"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Open secret scanning, code scanning and Dependabot alerts across the organisation's repositories, newest first, by kind and time, with the repository, the severity and whether a secret is still valid."
        static let input = JSONSchema.object([
            "kind": .string("Only this kind: secrets found in code, code scanning results or vulnerable dependencies. All three when left out.",
                            oneOf: ["secret", "code", "dependency"]),
            "since": .string("The earliest time each was raised, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kinds = try input.kind.map { [AlertKind(rawValue: try ServiceInput.oneOf($0, ["secret", "code", "dependency"], "kind"))!] }
                ?? AlertKind.allCases
            let since = try input.since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast }
            let (found, failures) = try await GitHub.eachFeed(kinds.map { kind in
                (kind, { try await GitHub.openAlerts(kind, on: service).map { (kind, $0) } })
            })
            let alerts = found.compactMap { kind, alert -> (AlertKind, SecurityAlert, Date)? in
                guard let time = ServiceAlert.time(alert.created_at), time >= since ?? .distantPast else { return nil }
                return (kind, alert, time)
            }.sorted { $0.2 > $1.2 }
            let lines = alerts.prefix(50).map { kind, alert, _ in
                var line = "\(alert.created_at ?? "?") \(kind.title): "
                switch kind {
                case .secret: line += "\(alert.secret_type_display_name ?? "secret")\(alert.validity.map { " (\($0))" } ?? "")"
                case .code: line += "\(alert.rule?.security_severity_level ?? "?") \(alert.rule?.description ?? "finding")"
                case .dependency:
                    line += "\(alert.security_advisory?.severity ?? "?") \(alert.security_advisory?.summary ?? "advisory") in \(alert.dependency?.package?.name ?? "a dependency")"
                }
                return line + " in \(alert.repository?.full_name ?? "?")"
            }
            let text = (lines.isEmpty ? ["No open alerts match."] : lines) + failures
            struct Alerts: Encodable { let alerts: [SecurityAlert] }
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Alerts(alerts: alerts.map(\.1)))
        }
    }

    /// New open alerts: every leaked secret, and code scanning and Dependabot alerts that are high or critical.
    struct NewSecurityAlerts: ServiceTrigger {
        var tool: String { SecurityAlerts.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            let (found, _) = try await GitHub.eachFeed([
                (AlertKind.secret, { try await GitHub.openAlerts(.secret, on: service) }),
                (AlertKind.code, {
                    try await GitHub.openAlerts(.code, severity: "critical", on: service) + GitHub.openAlerts(.code, severity: "high", on: service)
                }),
                (AlertKind.dependency, { try await GitHub.openAlerts(.dependency, severity: "critical,high", on: service) }),
            ])
            var seen = Set<String>()
            return found.compactMap { alert -> ServiceAlert? in
                guard let id = alert.html_url, let time = ServiceAlert.time(alert.created_at), time >= since, seen.insert(id).inserted else { return nil }
                return ServiceAlert(id: id, time: time)
            }.sorted { $0.time > $1.time }
        }
    }
}

extension GitHub {
    /// Teams and their members, from read:org: a team carries access to repositories, so who is in which team says what
    /// a member reaches. Which repositories each team holds needs a scope that also writes, so it is not read.
    struct Teams: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "teams"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The organisation's teams, with their members and the team each sits within."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Parent: Codable { let slug: String? }
            struct Team: Codable { let slug: String; let name: String?; let privacy: String?; let parent: Parent? }
            struct Member: Codable { let login: String }
            let teams = try await service.get(["teams"], query: ["per_page": "100"], as: [Team].self)
            let members = try await withThrowingTaskGroup(of: (String, [String]).self) { group in
                for team in teams {
                    group.addTask { (team.slug, try await service.get(["teams", team.slug, "members"], query: ["per_page": "100"], as: [Member].self).map(\.login)) }
                }
                return try await group.reduce(into: [String: [String]]()) { $0[$1.0] = $1.1 }
            }
            let names = Dictionary(teams.map { ($0.slug, $0.name ?? $0.slug) }, uniquingKeysWith: { first, _ in first })
            let text = teams.isEmpty ? "The organisation has no teams." : teams.map { team in
                let within = team.parent?.slug.map { ", within \(names[$0] ?? $0)" } ?? ""
                let secret = team.privacy == "secret" ? ", secret" : ""
                let held = members[team.slug] ?? []
                return "\(team.name ?? team.slug)\(within)\(secret) (\(held.count)): \(held.isEmpty ? "no members" : held.joined(separator: ", "))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let team: Team; let members: [String] }
            return try ServiceResult(text: text, structured: ["teams": teams.map { Kept(team: $0, members: members[$0.slug] ?? []) }])
        }
    }
}

