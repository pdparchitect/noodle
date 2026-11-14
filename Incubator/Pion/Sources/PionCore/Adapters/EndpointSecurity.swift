import Foundation
import NoodleCore
import NoodleMCP

/// A value as an FQL or filter string, refused when it holds a quote or backslash that could end it early.
private func quotedValue(_ value: String, _ name: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 200, !value.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
        throw ServiceError.input("Give \(name) without quotes or backslashes.")
    }
    return value
}

/// CrowdStrike Falcon: its hosts and the alerts its sensors raised, read with an API client's ID and secret.
/// Each account is one Falcon cloud and customer.
public enum CrowdStrike {
    public static let preset = ToolDefinition(
        id: "crowdstrike", name: "CrowdStrike Falcon", summary: "Hosts and the alerts Falcon raised on them, with what ran and how.",
        defaultInstructions: """
        Use CrowdStrike Falcon to see an endpoint as its sensor does: find a host by name or IP address, with its status, \
        whether it is contained and when it was last seen, and list alerts by host, severity and time, with the process, \
        command line and MITRE technique. Record each finding as evidence, citing the host and alert. These tools only read: \
        recommend containing a host or other responses to the champion.
        """,
        iconName: "crowdstrike",
        configuration: .mcp(.init(endpointTemplate: "https://{region}",
            fields: [ToolField(key: "region", title: "Falcon cloud", placeholder: "api.crowdstrike.com", kind: .choice([
                .init(value: "api.crowdstrike.com", title: "US-1"), .init(value: "api.us-2.crowdstrike.com", title: "US-2"),
                .init(value: "api.eu-1.crowdstrike.com", title: "EU-1"), .init(value: "api.laggar.gcw.crowdstrike.com", title: "US-GOV-1"),
            ]))],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://{region}/oauth2/token"), adapter: "crowdstrike")))

    public static let adapter = OperationAdapter(operations: [FindHost(), Alerts()])

    /// Falcon wraps lists in its resources.
    struct Resources<Item: Decodable>: Decodable { let resources: [Item]? }
}

extension CrowdStrike {
    struct FindHost: ServiceOperation {
        struct Input: Decodable, Sendable { let hostname: String?, ip: String? }
        static let name = "find-host"
        static let summary = "Find hosts by exact hostname or IP address, with their OS, sensor, status, containment and when last seen."
        static let input = JSONSchema.object([
            "hostname": .string("The host's exact name."),
            "ip": .string("A local or external IP address of the host."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let filter: String
            if let hostname = input.hostname { filter = "hostname:'\(try quotedValue(hostname, "the hostname"))'" }
            else if let ip = input.ip { let ip = try ServiceInput.ip(ip); filter = "local_ip:'\(ip)',external_ip:'\(ip)'" }
            else { throw ServiceError.input("Give a hostname or an IP address.") }
            let ids = try await service.get(["devices", "queries", "devices", "v1"], query: ["filter": filter, "limit": "10"],
                                            as: Resources<String>.self).resources ?? []
            struct Host: Codable {
                let device_id: String, hostname: String?, local_ip: String?, external_ip: String?, platform_name: String?
                let os_version: String?, agent_version: String?, last_seen: String?, first_seen: String?, status: String?
            }
            struct Hosts: Encodable { let hosts: [Host] }
            let hosts = ids.isEmpty ? [] : try await service.get(["devices", "entities", "devices", "v2"],
                                                                 query: ["ids": ids.joined(separator: ",")], as: Resources<Host>.self).resources ?? []
            let text = hosts.isEmpty ? "No host matches." : hosts.map { host in
                "\(host.hostname ?? host.device_id): \(host.status ?? "unknown status"), \([host.os_version, host.local_ip, host.external_ip].compactMap { $0 }.joined(separator: ", ")), sensor \(host.agent_version ?? "?"), last seen \(host.last_seen ?? "never")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Hosts(hosts: hosts))
        }
    }

    struct Alerts: ServiceOperation {
        struct Input: Decodable, Sendable { let hostname: String?, severity: String?, since: String?, limit: Int? }
        static let name = "alerts"
        static let summary = "Alerts Falcon raised, newest first, by host, severity and time, with the file, command line and MITRE technique."
        static let input = JSONSchema.object([
            "hostname": .string("The host's exact name."),
            "severity": .string("The severity.", oneOf: ["Informational", "Low", "Medium", "High", "Critical"]),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "limit": .integer("How many alerts, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter = ["created_timestamp:>='\(try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7))'"]
            if let hostname = input.hostname { filter.append("device.hostname:'\(try quotedValue(hostname, "the hostname"))'") }
            if let severity = input.severity {
                filter.append("severity_name:'\(try ServiceInput.oneOf(severity, ["Informational", "Low", "Medium", "High", "Critical"], "severity"))'")
            }
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 alerts.") }
            let ids = try await service.get(["alerts", "queries", "alerts", "v2"],
                query: ["filter": filter.joined(separator: "+"), "sort": "created_timestamp.desc", "limit": String(limit)],
                as: Resources<String>.self).resources ?? []
            struct Device: Codable { let hostname: String?; let device_id: String? }
            struct Alert: Codable {
                let composite_id: String, name: String?, description: String?, severity_name: String?, status: String?
                let created_timestamp: String?, tactic: String?, technique: String?, filename: String?, cmdline: String?
                let sha256: String?, device: Device?, falcon_host_link: String?
            }
            struct Alerts: Encodable { let alerts: [Alert] }
            struct Request: Encodable { let composite_ids: [String] }
            let alerts = ids.isEmpty ? [] : try await service.post(["alerts", "entities", "alerts", "v2"], body: Request(composite_ids: ids),
                                                                   as: Resources<Alert>.self).resources ?? []
            let text = alerts.isEmpty ? "No alerts match." : "\(alerts.count) alert\(alerts.count == 1 ? "" : "s"), newest first:\n" + alerts.prefix(20).map { alert in
                var line = "\(alert.created_timestamp ?? "?") \(alert.severity_name ?? "?") \(alert.status ?? "?"): \(alert.name ?? alert.composite_id)"
                if let host = alert.device?.hostname { line += " on \(host)" }
                if let file = alert.filename { line += " — \(file)" }
                if let command = alert.cmdline { line += " `\(command.prefix(200))`" }
                if let technique = alert.technique { line += " (\(technique))" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Alerts(alerts: alerts))
        }
    }
}

/// SentinelOne: its agents and the threats they found, read with an API token. Each account is one console.
public enum SentinelOne {
    public static let preset = ToolDefinition(
        id: "sentinelone", name: "SentinelOne", summary: "Agents and the threats they detected, with how each was mitigated.",
        defaultInstructions: """
        Use SentinelOne to see endpoints as its agents do: find an agent by computer name, with whether it is connected, \
        infected and when it was last active, and list threats by computer and time, with their classification, confidence, \
        file and mitigation. Record each finding as evidence, citing the computer and threat. These tools only read: \
        recommend isolating an endpoint or other responses to the champion.
        """,
        iconName: "sentinelone",
        configuration: .mcp(.init(endpointTemplate: "https://{console}/web/api/v2.1",
            fields: [ToolField(key: "console", title: "Console address", placeholder: "acme.sentinelone.net", kind: .host)],
            tokenHeader: "Authorization", tokenScheme: "ApiToken", adapter: "sentinelone")))

    public static let adapter = OperationAdapter(operations: [FindAgent(), Threats()])

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
            let name = try quotedValue(input.computerName, "the computer name")
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
            if let name = input.computerName { query["computerName__contains"] = try quotedValue(name, "the computer name") }
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
