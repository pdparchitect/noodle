import Foundation
import NoodleCore
import NoodleToolConnections

/// Sentry, read through its web API with a personal or internal integration token: an organisation's projects, its issues and
/// the latest event behind one. Sentry's own service and a self-hosted Sentry are two entries over the same operations.
public enum Sentry {
    static let instructions = """
        Use Sentry to see what errors the organisation's services raised around the incident: list projects, search \
        issues by query, project and period, and read an issue's latest event, with its exception, the frames in the \
        service's own code, the request, the user and its tags. Record each issue and event as evidence, citing the \
        project, the issue's short ID and the period. These tools only read: recommend resolving or ignoring an issue to \
        the champion.
        """

    public static let cloud = ToolDefinition(
        id: "7b2b1f8e-5d0c-4b4e-9a53-0d6e2f1c8a41", name: "Sentry", summary: "Projects, issues and the events behind them, read-only.",
        defaultInstructions: instructions, iconName: "sentry",
        configuration: .connection(.init(endpointTemplate: "https://{region}/api/0/organizations/{org}",
            fields: [ToolField(key: "region", title: "Region", placeholder: "sentry.io", kind: .choice([
                         .init(value: "sentry.io", title: "United States"), .init(value: "de.sentry.io", title: "European Union")])),
                     ToolField(key: "org", title: "Organisation", placeholder: "kestrel-labs", kind: .identifier)],
            tokenHeader: "Authorization", adapter: "sentry")),
        setup: cloudSetup)

    public static let server = ToolDefinition(
        id: "c1d64a3e-2f9b-4c7a-8e15-6b0f4d2a9e73", name: "Self-Hosted Sentry", summary: "A self-hosted Sentry: projects, issues and the events behind them, read-only.",
        defaultInstructions: instructions, iconName: "sentry",
        configuration: .connection(.init(endpointTemplate: "{address}/api/0/organizations/{org}",
            fields: [ToolField(key: "address", title: "Sentry address", placeholder: "http://sentry.example.lan:9000", kind: .address),
                     ToolField(key: "org", title: "Organisation", placeholder: "sentry", kind: .identifier)],
            tokenHeader: "Authorization", adapter: "sentry")),
        setup: serverSetup)

    static let token = [
        "In Sentry, open **User Settings › Personal Tokens**, at `/settings/account/api/auth-tokens/`, and choose **Create New Token**. Name it, such as Pion.",
        "Give it **Read** for **Project**, **Issue & Event** and **Organization** (`project:read`, `event:read` and `org:read`), and nothing else. Organization starts at No Access; without it, Sentry refuses every request.",
        "Copy the token at once, since Sentry shows it only then, and paste it here. It reads only what your own account may see.",
        "For a Sentry a team shares, an organisation owner or manager can instead make an internal integration, under **Settings › Developer Settings › Custom Integrations**, with the same permissions, so access does not depend on one person's account.",
    ]

    static let cloudSetup = token + [
        "For the organisation, give its slug, from the address you open Sentry at: `kestrel-labs` in `kestrel-labs.sentry.io`. Choose the region your organisation is in.",
    ]

    static let serverSetup = token + [
        "For the address, give the one you open Sentry at, such as `http://sentry.example.lan:9000`; plain `http` works only on this Mac or the local network. For the organisation, give its slug, from the address of any Sentry page: `kestrel-labs` in `/organizations/kestrel-labs/` or `/settings/kestrel-labs/`.",
    ]

    public static let adapter = OperationAdapter(operations: [Projects(), Issues(), IssueEvent()])

    /// A period as Sentry takes it: a number and h, d or w, such as 24h or 14d.
    static func period(_ value: String?) throws -> String {
        let value = (value ?? "24h").trimmingCharacters(in: .whitespaces)
        guard let unit = value.last, "hdw".contains(unit), let amount = Int(value.dropLast()), (1...999).contains(amount) else {
            throw ServiceError.input("Give the period as hours, days or weeks, such as 24h, 14d or 2w.")
        }
        return value
    }
}

extension Sentry {
    struct Projects: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "projects"
        static let summary = "The organisation's projects, with each one's ID, slug and platform."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Project: Codable { let id: String?; let slug: String?; let name: String?; let platform: String? }
            let projects = try await service.get(["projects"], trailingSlash: true, as: [Project].self)
            let text = projects.isEmpty ? "The organisation has no projects." : projects.map {
                "\($0.name ?? $0.slug ?? "?") (\($0.slug ?? "?"), ID \($0.id ?? "?"))\($0.platform.map { ", \($0)" } ?? "")"
            }.joined(separator: "\n")
            struct Kept: Encodable { let projects: [Project] }
            return try ServiceResult(text: text, structured: Kept(projects: projects))
        }
    }

    struct Issues: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String?, project: String?, period: String?, sort: String?, limit: Int? }
        static let name = "issues"
        static let summary = "Search the organisation's issues, with each one's short ID, level, status, counts and when it was first and last seen."
        static let input = JSONSchema.object([
            "query": .string("Sentry's issue search, such as is:unresolved level:error or user.email:a@b.c. Unresolved issues when left out."),
            "project": .string("Only this project, by its ID from projects."),
            "period": .string("How far back: 24h, 14d or 2w. The last day when left out."),
            "sort": .string("The order.", oneOf: ["date", "new", "freq", "user"]),
            "limit": .integer("How many issues, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 issues.") }
            if let project = input.project, !project.allSatisfy(\.isNumber) || project.isEmpty {
                throw ServiceError.input("Give the project by its ID from projects, such as 4504.")
            }
            struct Project: Codable { let slug: String? }
            struct Issue: Codable {
                let id: String?, shortId: String?, title: String?, culprit: String?, level: String?, status: String?
                let count: String?, userCount: Int?, firstSeen: String?, lastSeen: String?, permalink: String?, project: Project?
            }
            let issues = try await service.get(["issues"], query: [
                "query": try ServiceInput.query(input.query ?? "is:unresolved", limit: 1_000), "statsPeriod": try Sentry.period(input.period),
                "project": input.project, "sort": try input.sort.map { try ServiceInput.oneOf($0, ["date", "new", "freq", "user"], "sort") },
                "limit": String(limit),
            ], trailingSlash: true, as: [Issue].self)
            let text = issues.isEmpty ? "No issues match." : issues.map { issue in
                "\(issue.shortId ?? issue.id ?? "?") [\(issue.level ?? "?"), \(issue.status ?? "?")] \(issue.title ?? "")"
                    + " — \(issue.count ?? "?") events, \(issue.userCount ?? 0) users, last seen \(issue.lastSeen ?? "?")"
                    + (issue.project?.slug.map { " in \($0)" } ?? "") + " (ID \(issue.id ?? "?"))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let issues: [Issue] }
            return try ServiceResult(text: text, structured: Kept(issues: issues))
        }
    }

    struct IssueEvent: ServiceOperation {
        struct Input: Decodable, Sendable { let issue: String }
        static let name = "issue-event"
        static let summary = "An issue's latest event: its exception and the frames in the service's own code, the request, the user and its tags."
        static let input = JSONSchema.object(["issue": .string("The issue's ID, from issues.")], required: ["issue"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let issue = input.issue.trimmingCharacters(in: .whitespaces)
            guard !issue.isEmpty, issue.count <= 20, issue.allSatisfy(\.isNumber) else {
                throw ServiceError.input("Give the issue by its ID from issues, such as 5203481129.")
            }
            struct Frame: Codable { let filename: String?; let function: String?; let lineNo: Int?; let inApp: Bool? }
            struct Trace: Codable { let frames: [Frame]? }
            struct Exception: Codable { let type: String?; let value: String?; let stacktrace: Trace? }
            struct EntryData: Decodable { let values: [Exception]?; let url: String?; let method: String? }
            struct Entry: Decodable { let type: String; let data: EntryData? }
            struct Tag: Codable { let key: String; let value: String }
            struct User: Codable { let id: String?; let email: String?; let ip_address: String?; let username: String? }
            struct Event: Decodable {
                let eventID: String?, title: String?, dateCreated: String?, entries: [Entry]?, tags: [Tag]?, user: User?
            }
            let event = try await service.get(["issues", issue, "events", "latest"], trailingSlash: true, as: Event.self)
            let exceptions = (event.entries ?? []).filter { $0.type == "exception" }.flatMap { $0.data?.values ?? [] }
            let request = (event.entries ?? []).first { $0.type == "request" }?.data
            // The service's own frames, innermost last as Sentry lists them; the rest are libraries.
            func ownFrames(_ exception: Exception) -> [Frame] {
                Array((exception.stacktrace?.frames ?? []).filter { $0.inApp == true }.suffix(10))
            }
            var lines = ["\(event.title ?? "Event") at \(event.dateCreated ?? "?") (event \(event.eventID ?? "?"))"]
            for exception in exceptions {
                lines.append("\(exception.type ?? "Exception"): \(exception.value ?? "")")
                lines += ownFrames(exception).map { "    at \($0.function ?? "?") (\($0.filename ?? "?"):\($0.lineNo.map(String.init) ?? "?"))" }
            }
            if let request, let url = request.url { lines.append("Request: \(request.method ?? "") \(url)") }
            if let user = event.user {
                let who = [user.email, user.username, user.id, user.ip_address].compactMap { $0 }.joined(separator: ", ")
                if !who.isEmpty { lines.append("User: \(who)") }
            }
            if let tags = event.tags, !tags.isEmpty { lines.append("Tags: " + tags.prefix(20).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
            struct KeptException: Encodable { let type: String?, value: String?, frames: [Frame] }
            struct Kept: Encodable {
                let event: String?, title: String?, date: String?, exceptions: [KeptException], request: String?, user: User?, tags: [Tag]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                event: event.eventID, title: event.title, date: event.dateCreated,
                exceptions: exceptions.map { KeptException(type: $0.type, value: $0.value, frames: ownFrames($0)) },
                request: request.flatMap { request in request.url.map { "\(request.method ?? "") \($0)" } }, user: event.user, tags: event.tags ?? []))
        }
    }
}
