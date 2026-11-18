import Foundation
import NoodleCore
import NoodleMCP

/// CrowdStrike Falcon: its hosts and the alerts its sensors raised, read with an API client's ID and secret.
/// Each account is one Falcon cloud and customer.
public enum CrowdStrike {
    public static let preset = ToolDefinition(
        id: "fc56ba9d-c4aa-4ff9-80cf-507f21273249", name: "CrowdStrike Falcon", summary: "Hosts and the alerts Falcon raised on them, with what ran and how.",
        defaultInstructions: """
        Use CrowdStrike Falcon to see an endpoint as its sensor does: find a host by name or IP address, with its status, \
        whether it is contained and when it was last seen, and list alerts by host, severity and time, with the process, \
        command line and MITRE technique. Record each finding as evidence, citing the host and alert. These tools only read: \
        recommend containing a host or other responses to the champion.
        """,
        iconName: "crowdstrike",
        configuration: .connection(.init(endpointTemplate: "https://{region}",
            fields: [ToolField(key: "region", title: "Falcon cloud", placeholder: "api.crowdstrike.com", kind: .choice([
                .init(value: "api.crowdstrike.com", title: "US-1"), .init(value: "api.us-2.crowdstrike.com", title: "US-2"),
                .init(value: "api.eu-1.crowdstrike.com", title: "EU-1"), .init(value: "api.laggar.gcw.crowdstrike.com", title: "US-GOV-1"),
            ]))],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://{region}/oauth2/token"), adapter: "crowdstrike")),
        setup: setup)

    static let setup = [
        "In the Falcon console, open **Support and resources › API clients and keys** and choose **Create API client**.",
        "Name it, such as Pion, and give it only **Hosts: Read** and **Alerts: Read**.",
        "Copy the **Client ID** and **Secret** here; the secret is shown only once.",
        "For the Falcon cloud, choose the one your console's address names: `falcon.us-2.crowdstrike.com` is US-2, and `falcon.crowdstrike.com` is US-1.",
    ]

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
            if let hostname = input.hostname { filter = "hostname:'\(try ServiceInput.quoted(hostname, "the hostname"))'" }
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
            if let hostname = input.hostname { filter.append("device.hostname:'\(try ServiceInput.quoted(hostname, "the hostname"))'") }
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
