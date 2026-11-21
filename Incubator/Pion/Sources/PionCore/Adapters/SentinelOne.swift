import Foundation
import NoodleCore
import NoodleToolConnections

/// SentinelOne: its agents and the threats they found, read with an API token. Each account is one console.
public enum SentinelOne {
    public static let preset = ToolDefinition(
        id: "9d1c01e9-bb44-4a66-876a-e60b48337ca3", name: "SentinelOne", summary: "Agents and the threats they detected, with how each was mitigated.",
        defaultInstructions: """
        Use SentinelOne to see endpoints as its agents do: find an agent by computer name, with whether it is connected, \
        infected and when it was last active, and list threats by computer and time, with their classification, confidence, \
        file and mitigation. Record each finding as evidence, citing the computer and threat. These tools only read: \
        recommend isolating an endpoint or other responses to the champion.
        """,
        iconName: "sentinelone",
        configuration: .connection(.init(endpointTemplate: "https://{console}/web/api/v2.1",
            fields: [ToolField(key: "console", title: "Console address", placeholder: "acme.sentinelone.net", kind: .host)],
            tokenHeader: "Authorization", tokenScheme: "ApiToken", adapter: "sentinelone")),
        setup: setup)

    static let setup = [
        "In the SentinelOne console, open **Settings › Users › Service Users** and choose **Create New Service User**.",
        "Give it the **Viewer** role, scoped to the account or site to investigate, and an expiry date.",
        "Copy the API token it shows and paste it here; it is shown only once.",
        "For the console address, give your console's host, such as `acme.sentinelone.net`.",
    ]

    public static let adapter = OperationAdapter(operations: [FindAgent(), Threats()], trigger: NewThreats())

    /// Every new threat an agent detects: SentinelOne gives threats no severity, and each is serious.
    struct NewThreats: ServiceTrigger {
        var tool: String { Threats.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            struct Info: Decodable { let createdAt: String? }
            struct Threat: Decodable { let id: String; let threatInfo: Info? }
            return (try await service.get(["threats"], query: ["createdAt__gte": ISO8601DateFormatter().string(from: since),
                                                              "sortBy": "createdAt", "sortOrder": "desc", "limit": String(ServiceAlert.most)],
                                          as: Page<Threat>.self).data ?? [])
                .compactMap { threat in ServiceAlert.time(threat.threatInfo?.createdAt).map { ServiceAlert(id: threat.id, time: $0) } }
                .sorted { $0.time > $1.time }
        }
    }

    /// SentinelOne wraps lists in their data.
    struct Page<Item: Decodable>: Decodable { let data: [Item]? }
}

extension SentinelOne {
    struct FindAgent: ServiceOperation {
        struct Input: Decodable, Sendable { let computerName: String }
        static let name = "find-agent"
        static let summary = "Find agents whose computer name contains the text, with their OS, connection, infection and last activity."
        static let input = JSONSchema.object(["computerName": .string("All or part of the computer's name.")], required: ["computerName"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let name = try ServiceInput.quoted(input.computerName, "the computer name")
            struct Agent: Codable {
                let id: String, computerName: String?, osName: String?, networkStatus: String?, isActive: Bool?, infected: Bool?
                let activeThreats: Int?, lastActiveDate: String?, externalIp: String?, agentVersion: String?, siteName: String?
            }
            struct Agents: Encodable { let agents: [Agent] }
            let agents = try await service.get(["agents"], query: ["computerName__contains": name, "limit": "10"], as: Page<Agent>.self).data ?? []
            let text = agents.isEmpty ? "No agent matches \"\(name)\"." : agents.map { agent in
                var line = "\(agent.computerName ?? agent.id): \(agent.networkStatus ?? "unknown")"
                if agent.infected == true { line += ", infected (\(agent.activeThreats ?? 0) active threat\(agent.activeThreats == 1 ? "" : "s"))" }
                line += ", \([agent.osName, agent.externalIp, agent.siteName].compactMap { $0 }.joined(separator: ", ")), last active \(agent.lastActiveDate ?? "never")"
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Agents(agents: agents))
        }
    }

    struct Threats: ServiceOperation {
        struct Input: Decodable, Sendable { let computerName: String?, unresolvedOnly: Bool?, since: String?, limit: Int? }
        static let name = "threats"
        static let summary = "Threats agents detected, newest first, by computer and time, with classification, confidence, file and mitigation."
        static let input = JSONSchema.object([
            "computerName": .string("All or part of the computer's name."),
            "unresolvedOnly": .boolean("Only threats not yet resolved."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "limit": .integer("How many threats, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 threats.") }
            var query: [String: String?] = ["createdAt__gt": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7),
                                            "sortBy": "createdAt", "sortOrder": "desc", "limit": String(limit)]
            if let name = input.computerName { query["computerName__contains"] = try ServiceInput.quoted(name, "the computer name") }
            if input.unresolvedOnly == true { query["resolved"] = "false" }
            struct Info: Codable {
                let threatName: String?, classification: String?, confidenceLevel: String?, mitigationStatus: String?
                let analystVerdict: String?, createdAt: String?, sha256: String?, filePath: String?
            }
            struct Agent: Codable { let agentComputerName: String? }
            struct Threat: Codable { let id: String; let threatInfo: Info?; let agentRealtimeInfo: Agent? }
            struct Threats: Encodable { let threats: [Threat] }
            let threats = try await service.get(["threats"], query: query, as: Page<Threat>.self).data ?? []
            let text = threats.isEmpty ? "No threats match." : "\(threats.count) threat\(threats.count == 1 ? "" : "s"), newest first:\n" + threats.prefix(20).map { threat in
                let info = threat.threatInfo
                var line = "\(info?.createdAt ?? "?") \(info?.threatName ?? threat.id)"
                if let computer = threat.agentRealtimeInfo?.agentComputerName { line += " on \(computer)" }
                let details = [info?.classification, info?.confidenceLevel, info?.mitigationStatus].compactMap { $0 }
                if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
                if let path = info?.filePath { line += " — \(path)" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Threats(threats: threats))
        }
    }
}
