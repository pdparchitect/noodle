import Foundation
import NoodleCore
import NoodleToolConnections

/// Grafana, read through its HTTP API with a service account's token: dashboards and the queries behind their
/// panels, queries over its data sources, firing alerts and annotations. Grafana Cloud and a Grafana the person runs,
/// on this Mac, the local network or anywhere over HTTPS, are two entries over the same operations.
public enum Grafana {
    static let instructions = """
        Use Grafana to see what its data sources show around the incident: find dashboards, read the queries and data \
        source UIDs behind their panels, run a query over a data source (PromQL or LogQL for Prometheus and Loki, the \
        data source's own query language otherwise) over a time range, list firing alerts, and read annotations such as \
        deploys. Record each query and what it returned as evidence, with the query, data source and time range as the \
        method. These tools only read.
        """

    public static let cloud = ToolDefinition(
        id: "db2c8cc2-7773-433d-bf4b-539abc948e8d", name: "Grafana Cloud", summary: "Dashboards, queries over data sources, firing alerts and annotations.",
        defaultInstructions: instructions, iconName: "grafana",
        configuration: .connection(.init(endpointTemplate: "https://{host}/api",
            fields: [ToolField(key: "host", title: "Stack address", placeholder: "acme.grafana.net", kind: .host)],
            tokenHeader: "Authorization", adapter: "grafana")),
        setup: cloudSetup)

    public static let server = ToolDefinition(
        id: "ff724613-f97d-48f6-aeb0-165ad72e8f98", name: "Self-Hosted Grafana", summary: "A self-hosted Grafana: dashboards, queries over data sources, firing alerts and annotations.",
        defaultInstructions: instructions, iconName: "grafana",
        configuration: .connection(.init(endpointTemplate: "{address}/api",
            fields: [ToolField(key: "address", title: "Grafana address", placeholder: "http://localhost:3000", kind: .address)],
            tokenHeader: "Authorization", adapter: "grafana")),
        setup: serverSetup)

    static let token = [
        "Choose **Add service account token**, give it an expiry date, then copy the token and paste it here; it is shown only once.",
        "Viewer reads dashboards, alerts and annotations and queries data sources. If agents cannot list data sources, they find each one's UID in dashboards' panels.",
    ]

    static let cloudSetup = [
        "In your Grafana Cloud stack, open **Administration › Users and access › Service accounts** and choose **Add service account**. Name it, such as Pion, and give it the **Viewer** role.",
    ] + token + [
        "For the stack address, give its host, such as `acme.grafana.net`.",
    ]

    static let serverSetup = [
        "In Grafana, open **Administration › Users and access › Service accounts** and choose **Add service account**. Name it, such as Pion, and give it the **Viewer** role.",
    ] + token + [
        "For the address, give the one you open Grafana at, such as `http://localhost:3000` or `https://grafana.example.com`. Plain `http` works only on this Mac or the local network.",
    ]

    public static let adapter = OperationAdapter(operations: [Dashboards(), Dashboard(), DataSources(), Query(), Alerts(), Annotations()])

    /// A time as Grafana takes it: now, now-6h and the like, or ISO 8601, which goes as epoch milliseconds.
    static func time(_ value: String?, default fallback: String) throws -> String {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
        if value.count <= 20, value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "now+-/0123456789smhdwMy").contains), value.hasPrefix("now") {
            return value
        }
        let plain = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: value) ?? precise.date(from: value) else {
            throw ServiceError.input("Give times as now, now-6h, now-7d or ISO 8601.")
        }
        return String(Int64(date.timeIntervalSince1970 * 1000))
    }

    /// A UID as Grafana makes them: letters, digits, hyphens and underscores.
    static func uid(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains) else {
            throw ServiceError.input("Give \(name) as Grafana shows it, such as P1809F7CD0C75ACF3.")
        }
        return value
    }
}

extension Grafana {
    struct Dashboards: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String?, tag: String?, limit: Int? }
        static let name = "dashboards"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Find dashboards by title or tag, with each one's UID, folder and tags."
        static let input = JSONSchema.object([
            "query": .string("Words in the title. Every dashboard when left out."),
            "tag": .string("Only dashboards with this tag."),
            "limit": .integer("How many, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 30
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 dashboards.") }
            struct Item: Codable { let uid: String?; let title: String?; let folderTitle: String?; let tags: [String]? }
            let items = try await service.get(["search"], query: [
                "type": "dash-db", "limit": String(limit), "query": try input.query.map { try ServiceInput.query($0, limit: 200) },
                "tag": try input.tag.map { try ServiceInput.query($0, limit: 100) },
            ], as: [Item].self)
            let text = items.isEmpty ? "No dashboards match." : items.map { item in
                "\(item.title ?? "Untitled") (\(item.uid ?? "?"))\(item.folderTitle.map { " in \($0)" } ?? "")"
                    + ((item.tags ?? []).isEmpty ? "" : " [\((item.tags ?? []).joined(separator: ", "))]")
            }.joined(separator: "\n")
            struct Kept: Encodable { let dashboards: [Item] }
            return try ServiceResult(text: text, structured: Kept(dashboards: items))
        }
    }

    struct Dashboard: ServiceOperation {
        struct Input: Decodable, Sendable { let uid: String }
        static let name = "dashboard"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "A dashboard's panels, each with its data source and the queries behind it, to run again with query."
        static let input = JSONSchema.object(["uid": .string("The dashboard's UID, from dashboards.")], required: ["uid"])

        /// A panel's or query's data source: a UID with its type, or in older dashboards only a name.
        struct Source: Decodable {
            let uid: String?, type: String?, name: String?
            init(from decoder: Decoder) throws {
                if let name = try? decoder.singleValueContainer().decode(String.self) { uid = nil; type = nil; self.name = name; return }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                uid = try? container.decode(String.self, forKey: .uid)
                type = try? container.decode(String.self, forKey: .type)
                name = nil
            }
            enum CodingKeys: String, CodingKey { case uid, type }
            var shown: String { [type, uid ?? name].compactMap { $0 }.joined(separator: " ") }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Target: Decodable {
                let refId: String?, expr: String?, query: String?, rawSql: String?, datasource: Source?
                var text: String? { expr ?? rawSql ?? query }
            }
            struct Panel: Decodable { let title: String?; let type: String?; let datasource: Source?; let targets: [Target]?; let panels: [Panel]? }
            struct Board: Decodable { let title: String?; let panels: [Panel]? }
            struct Answer: Decodable { let dashboard: Board }
            let board = try await service.get(["dashboards", "uid", try Grafana.uid(input.uid, "the dashboard's UID")], as: Answer.self).dashboard
            // Rows hold their own panels when collapsed.
            let panels = (board.panels ?? []).flatMap { [$0] + ($0.panels ?? []) }.filter { $0.type != "row" }
            struct KeptQuery: Encodable { let refId: String?, query: String?, datasource: String? }
            struct KeptPanel: Encodable { let title: String?, datasource: String?, queries: [KeptQuery] }
            let kept = panels.map { panel in
                KeptPanel(title: panel.title, datasource: panel.datasource?.shown, queries: (panel.targets ?? []).map {
                    KeptQuery(refId: $0.refId, query: $0.text, datasource: ($0.datasource ?? panel.datasource)?.shown)
                })
            }
            var lines = ["\(board.title ?? "Untitled"): \(kept.count) panel\(kept.count == 1 ? "" : "s")"]
            for panel in kept {
                lines.append("- \(panel.title ?? "Untitled")\(panel.datasource.map { " [\($0)]" } ?? "")")
                lines += panel.queries.compactMap { query in query.query.map { "    \(query.refId ?? "?"): \($0)" } }
            }
            struct Kept: Encodable { let title: String?, panels: [KeptPanel] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(title: board.title, panels: kept))
        }
    }

    struct DataSources: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "data-sources"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The data sources, with each one's UID and type."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Source: Codable { let uid: String?; let name: String?; let type: String? }
            let sources: [Source]
            do { sources = try await service.get(["datasources"], as: [Source].self) }
            catch ServiceError.rejected, ServiceError.forbidden {
                throw ServiceError.refused("Grafana did not list its data sources: the token is wrong, or its role may not list them. Each one's UID is in dashboards' panels.")
            }
            let text = sources.isEmpty ? "There are no data sources." : sources.map { "\($0.name ?? "?") (\($0.type ?? "?")): \($0.uid ?? "?")" }.joined(separator: "\n")
            struct Kept: Encodable { let dataSources: [Source] }
            return try ServiceResult(text: text, structured: Kept(dataSources: sources))
        }
    }

    struct Query: ServiceOperation {
        struct Input: Decodable, Sendable { let datasource: String, query: String, from: String?, to: String? }
        static let name = "query"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Run one query over a data source and time range and return its results as rows. Read-only."
        static let input = JSONSchema.object([
            "datasource": .string("The data source's UID, from data-sources or a dashboard's panel."),
            "query": .string(#"The query in the data source's own form, as JSON, such as {"expr":"sum(rate(http_requests_total{code=~\"5..\"}[5m]))"} for Prometheus or Loki, or {"rawSql":"SELECT …","format":"table"} for SQL."#),
            "from": .string("The start: now-1h, now-7d or ISO 8601. The last hour when left out."),
            "to": .string("The end, in the same forms. Now when left out."),
        ], required: ["datasource", "query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let uid = try Grafana.uid(input.datasource, "the data source's UID")
            guard let model = try? JSONSerialization.jsonObject(with: Data(try ServiceInput.query(input.query).utf8)) as? [String: Any] else {
                throw ServiceError.input(#"Give the query as a JSON object, such as {"expr":"up"}."#)
            }
            // SQL reaches its database with whatever rights Grafana's user there has, so only statements that read go.
            if let sql = model["rawSql"] as? String {
                var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
                if statement.hasSuffix(";") { statement.removeLast() }
                let first = statement.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first?.lowercased()
                guard let first, ["select", "with", "show", "explain"].contains(first), !statement.contains(";") else {
                    throw ServiceError.input("SQL here only reads: one SELECT, WITH, SHOW or EXPLAIN statement.")
                }
            }
            var query = model
            query["refId"] = "A"
            query["datasource"] = ["uid": uid]
            query["maxDataPoints"] = query["maxDataPoints"] ?? 500
            let body: [String: Any] = ["queries": [query], "from": try Grafana.time(input.from, default: "now-1h"),
                                       "to": try Grafana.time(input.to, default: "now")]
            let data = try await service.data(["ds", "query"], method: "POST", body: try JSONSerialization.data(withJSONObject: body))
            return try Grafana.table(from: data).result()
        }
    }

    struct Alerts: ServiceOperation {
        struct Input: Decodable, Sendable { let filter: String? }
        static let name = "alerts"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Alerts Grafana is firing now, with their labels, summary and when they started."
        static let input = JSONSchema.object([
            "filter": .string("Only alerts whose labels match, such as severity=\"critical\"."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Alert: Decodable { let labels: [String: String]?; let annotations: [String: String]?; let startsAt: String? }
            let alerts = try await service.get(["alertmanager", "grafana", "api", "v2", "alerts"], query: [
                "active": "true", "silenced": "false", "inhibited": "false",
                "filter": try input.filter.map { try ServiceInput.query($0, limit: 200) },
            ], as: [Alert].self)
            struct Kept: Encodable { let name: String?, startsAt: String?, summary: String?, labels: [String: String] }
            let kept = alerts.map { alert in
                Kept(name: alert.labels?["alertname"], startsAt: alert.startsAt,
                     summary: alert.annotations?["summary"] ?? alert.annotations?["description"], labels: alert.labels ?? [:])
            }
            let text = kept.isEmpty ? "No alerts are firing." : kept.map { alert in
                let labels = alert.labels.filter { $0.key != "alertname" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                return "\(alert.name ?? "Alert") since \(alert.startsAt ?? "?")\(alert.summary.map { ": \($0)" } ?? "")"
                    + (labels.isEmpty ? "" : " [\(labels.joined(separator: ", "))]")
            }.joined(separator: "\n")
            struct List: Encodable { let alerts: [Kept] }
            return try ServiceResult(text: text, structured: List(alerts: kept))
        }
    }

    struct Annotations: ServiceOperation {
        struct Input: Decodable, Sendable { let from: String?, to: String?, tags: [String]?, limit: Int? }
        static let name = "annotations"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Annotations over a time range, such as deploys and incidents marked on dashboards, newest first."
        static let input = JSONSchema.object([
            "from": .string("The start: now-1h, now-7d or ISO 8601. The last day when left out."),
            "to": .string("The end, in the same forms. Now when left out."),
            "tags": .array(.string("A tag."), "Only annotations with all these tags."),
            "limit": .integer("How many, at most.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 annotations.") }
            func epoch(_ value: String?, _ fallback: String) throws -> String {
                let value = try Grafana.time(value, default: fallback)
                guard value.hasPrefix("now") else { return value }
                // The annotations API takes only epoch milliseconds, so relative times are worked out here.
                let units: [Character: Double] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400, "w": 604_800, "M": 2_592_000, "y": 31_536_000]
                var offset = 0.0
                let rest = value.dropFirst(3)
                if let sign = rest.first, sign == "-" || sign == "+", let unit = rest.last, let size = units[unit],
                   let amount = Double(rest.dropFirst().dropLast()) {
                    offset = (sign == "-" ? -1 : 1) * amount * size
                } else if !rest.isEmpty { throw ServiceError.input("Give annotation times as now-6h, now-7d or ISO 8601.") }
                return String(Int64((Date().timeIntervalSince1970 + offset) * 1000))
            }
            var query: [String: String?] = ["from": try epoch(input.from, "now-1d"), "to": try epoch(input.to, "now"), "limit": String(limit)]
            if let tags = input.tags, !tags.isEmpty {
                query["tags"] = try ServiceInput.list(tags, limit: 10) { try ServiceInput.query($0, limit: 100) }.joined(separator: ",")
                query["matchAny"] = "false"
            }
            struct Item: Decodable { let time: Double?; let text: String?; let tags: [String]?; let dashboardUID: String? }
            let items = try await service.get(["annotations"], query: query, as: [Item].self)
            let date = ISO8601DateFormatter()
            struct Kept: Encodable { let time: String?, text: String?, tags: [String], dashboard: String? }
            let kept = items.map { item in
                Kept(time: item.time.map { date.string(from: Date(timeIntervalSince1970: $0 / 1000)) }, text: item.text,
                     tags: item.tags ?? [], dashboard: item.dashboardUID)
            }
            let text = kept.isEmpty ? "No annotations in that time." : kept.map { item in
                "\(item.time ?? "?"): \(item.text ?? "")" + (item.tags.isEmpty ? "" : " [\(item.tags.joined(separator: ", "))]")
            }.joined(separator: "\n")
            struct List: Encodable { let annotations: [Kept] }
            return try ServiceResult(text: text, structured: List(annotations: kept))
        }
    }

    /// A query's answer as one table: each frame's rows, with the labels that tell its series apart in a column of
    /// their own, and times in ISO 8601.
    static func table(from data: Data) throws -> ServiceTable {
        struct Field: Decodable { let name: String; let type: String?; let labels: [String: String]? }
        struct Schema: Decodable { let name: String?; let fields: [Field] }
        struct Values: Decodable { let values: [[CellValue]] }
        struct Frame: Decodable { let schema: Schema?; let data: Values? }
        struct Result: Decodable { let error: String?; let frames: [Frame]? }
        struct Answer: Decodable { let results: [String: Result]? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw ServiceError.unreadable }
        let result = answer.results?["A"]
        if let error = result?.error { throw ServiceError.refused(error) }
        let frames = result?.frames ?? []
        let date = ISO8601DateFormatter()
        var columns: [String] = []
        var rows: [[String: CellValue]] = []
        let labelled = frames.contains { frame in frame.schema?.fields.contains { !($0.labels ?? [:]).isEmpty } == true }
        for frame in frames {
            guard let fields = frame.schema?.fields, let values = frame.data?.values else { continue }
            for field in fields where !columns.contains(field.name) { columns.append(field.name) }
            let labels = fields.compactMap(\.labels).flatMap { $0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let count = values.map(\.count).max() ?? 0
            for index in 0..<count {
                var row: [String: CellValue] = labelled ? ["series": .text(labels.joined(separator: ", "))] : [:]
                for (column, field) in fields.enumerated() where column < values.count && index < values[column].count {
                    var value = values[column][index]
                    if field.type == "time", case .number(let milliseconds) = value {
                        value = .text(date.string(from: Date(timeIntervalSince1970: milliseconds / 1000)))
                    }
                    row[field.name] = value
                }
                rows.append(row)
            }
        }
        if labelled { columns.insert("series", at: 0) }
        return ServiceTable(columns: columns, rows: rows.map { row in columns.map { row[$0] ?? .none } })
    }
}
