import CryptoKit
import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Azure: activity, security alerts, resources and access, reached as an app registered in the tenant.
/// Each account is one subscription. Microsoft Azure Detection only reads; Microsoft Azure Containment, a tool of its own
/// with an app registration of its own, acts.
public enum Azure {
    public static let preset = ToolDefinition(
        id: "bb70fbdc-96ea-4c56-91cf-b1b29fe91328", name: "Microsoft Azure Detection",
        summary: "Activity log, Defender for Cloud alerts, resources and access in an Azure subscription, read-only.",
        defaultInstructions: """
        Use Microsoft Azure Detection to investigate a subscription: activity-log searches its activity log by time, caller, \
        resource group, resource, resource provider, correlation ID, operation and outcome, with each event's caller IP, \
        claims and the permission it used; defender-alerts lists Microsoft Defender for Cloud alerts; resource-graph runs \
        KQL over its resources; role-assignments says who holds which role where, including roles eligible through \
        Privileged Identity Management; deny-assignments lists what is denied to whom. Keep queries narrow, with a time \
        filter and a row limit. The alert watch checks every five minutes and wakes you with a note naming \
        security-events, which reads what it reads for the note's window: open high-severity Defender for Cloud alerts, \
        and activity-log entries that open the way in or hide what follows: Owner, Contributor, User Access \
        Administrator or Role Based Access Control Administrator granted on the subscription, access to a Key Vault \
        granted or its access policies changed, diagnostic settings deleted, resource locks or policy assignments \
        deleted, network rules opened to the internet, commands run on VMs, storage opened to public or shared key \
        access, and a Global Administrator elevating access, which only the directory activity log holds. A note may \
        name a feed the watch could not read, such as no Defender plan turned on or a role missing; security-events \
        says which and why, so tell the champion what to change and treat that feed's silence as unknown. When a tool \
        is refused or something you need seems missing, run check-access and tell the champion exactly what it says to \
        change. Silence is not proof: every result says when it stopped before reading everything, when more matched \
        than it kept and what it could not read; report those gaps with what you found. The activity log keeps 90 days \
        and records changes, not reads of data; Defender for Cloud alerts exist only for the plans turned on. An \
        event's caller is the credential used, not who held it. Recipes: a new owner: security-events, then \
        activity-log operation Microsoft.Authorization/roleAssignments/write and role-assignments principalId; \
        commands on a VM: activity-log resource set to the VM and operation runCommand; one change in full: \
        activity-log correlationId. Record each query and what it returned as evidence, with the query itself as the \
        method. These tools only read: recommend changes to the champion, or use Microsoft Azure Containment.
        Defender for Cloud alerts may also appear in Microsoft Defender XDR (alerts_v2 serviceSource microsoftDefenderForCloud) under a different ID, so match them up.
        """,
        iconName: "azure",
        configuration: .connection(.init(endpointTemplate: "https://management.azure.com",
            fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier),
                     ToolField(key: "subscription", title: "Subscription ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000002", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                       scope: "https://management.azure.com/.default"),
            adapter: "azure")),
        setup: setup)

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it, such as Pion Detection, keep **Single tenant** and leave the redirect URI empty. It needs no API permissions.",
        "Under **Certificates & secrets**, add a client secret and copy its **Value**, not its Secret ID; it is shown only once.",
        "In the [Azure portal](https://portal.azure.com), open the subscription, choose **Access control (IAM) › Add role assignment**, and give the app the **Reader** and **Security Reader** roles. Neither can change anything.",
        "Optionally, to watch for a Global Administrator elevating access, which Azure records only in the directory's own activity log, have a Global Administrator give the app **Monitoring Reader** at the root scope (`/`). Without it the watch says it cannot read that log.",
        "Copy the **Subscription ID** from the subscription's **Overview**, and the **Directory (tenant) ID** and **Application (client) ID** from the app's **Overview**. Then choose **Add & Connect** and ask an agent to run check-access.",
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        ActivityLog(), SecurityEvents(), DefenderAlerts(), ResourceGraph(), RoleAssignments(), DenyAssignments(), CheckAccess(),
        RemoveRoleAssignment(), DeallocateVM(), IsolateVM(), UnisolateVM(), RotateStorageKey(), RestrictStorage(), AddLock(), SnapshotDisk(),
        SetAlertStatus(), CloseAlert(), OperationStatus(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents())

    // MARK: Versions and limits

    static let activityVersion = "2015-04-01", alertsVersion = "2022-01-01", authorizationVersion = "2022-04-01"
    static let graphVersion = "2022-10-01", pricingsVersion = "2024-01-01", eligibilityVersion = "2020-10-01"
    /// The most pages one listing reads.
    static let maximumPages = 20
    /// The most role definitions role-assignments looks up by name, one request each.
    static let definitionLookups = 40
    /// The most pages of Resource Graph rows one query reads, and the rows it reads before stopping: what a result keeps.
    static let graphPages = 5, graphRows = 100

    // MARK: Inputs

    static func guid(_ value: String) throws -> String {
        guard value.count == 36, UUID(uuidString: value) != nil else { throw ServiceError.input("Give the ID as a GUID.") }
        return value
    }

    static func subscription(_ service: ServiceClient) throws -> String { try guid(service.setting("subscription")) }

    static func path(_ service: ServiceClient, _ provider: String, _ resource: String) throws -> [String] {
        ["subscriptions", try subscription(service), "providers", provider, resource]
    }

    /// A full resource ID inside the account's subscription, as its path's parts, such as subscriptions, the
    /// subscription, resourceGroups, rg-prod, providers, Microsoft.Compute, virtualMachines and vm-one. Long IDs are
    /// taken, but nothing that could end a quoted filter or leave the path: no quotes, backslashes, line breaks, `?`,
    /// `#`, `%` or `..`. The subscription is always the account's own, whatever case it was given in.
    static func resource(_ value: String, _ service: ServiceClient, _ name: String = "the resource") throws -> [String] {
        let own = try subscription(service)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard value.count <= 2_048, value.hasPrefix("/"), parts.count >= 3, parts.dropFirst().allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && !part.contains(where: { "'\"\\?#%".contains($0) || $0.isWhitespace })
        }), parts[1].lowercased() == "subscriptions" else {
            throw ServiceError.input("Give \(name) as its full Azure resource ID, such as /subscriptions/\(own)/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm-one.")
        }
        guard parts[2].lowercased() == own.lowercased() else {
            throw ServiceError.input("\(name.prefix(1).uppercased() + name.dropFirst()) is in subscription \(parts[2]), not this account's, \(own): only this account's subscription can be read or changed.")
        }
        return ["subscriptions", own] + parts.dropFirst(3)
    }

    /// A resource ID of one type, such as Microsoft.Compute/virtualMachines, in a resource group of the subscription.
    static func resource(_ value: String, _ service: ServiceClient, type: String, _ name: String) throws -> [String] {
        let parts = try resource(value, service, name)
        let typeParts = type.split(separator: "/").map { $0.lowercased() }
        guard parts.count == 5 + typeParts.count + 1, parts[2].lowercased() == "resourcegroups", parts[4].lowercased() == "providers",
              Array(parts[5..<(5 + typeParts.count)]).map({ $0.lowercased() }) == typeParts else {
            throw ServiceError.input("Give \(name) as the full ID of a \(type), such as /subscriptions/\(parts[1])/resourceGroups/rg-prod/providers/\(type)/name.")
        }
        return parts
    }

    /// An ID a wake can carry: a fixed prefix naming its feed, and a digest of the service's own ID, so nothing a
    /// service wrote, however plain it looks, reaches the note that wakes an agent.
    static func safeID(_ prefix: String, _ value: String) -> String {
        prefix + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Listings

    struct List<Item: Decodable>: Decodable { let value: [Item]; let nextLink: String? }
    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// How many items the pages held before any were left out.
        var read = 0
        /// Why it stopped before the end, when not for its page limit.
        var stopped: String? = nil
    }

    /// A listing, page after page, up to `pages`. Only the next page's $skipToken is taken from Azure's nextLink, so
    /// every request goes to the connection's own host; a nextLink without one stops the listing, said so.
    static func list<Item: Decodable>(_ service: ServiceClient, path: [String], query: [String: String?],
                                      as: Item.Type, limit: Int? = nil, pages: Int = maximumPages,
                                      matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var query = query
        var found = Listing<Item>()
        while found.pages < pages {
            let page = try await service.get(path, query: query, as: List<Item>.self)
            found.pages += 1
            found.read += page.value.count
            found.value += page.value.filter(matching)
            found.more = page.nextLink?.isEmpty == false
            if !found.more || limit.map({ found.value.count >= $0 }) == true { break }
            guard let link = page.nextLink,
                  let token = URLComponents(string: link)?.queryItems?.first(where: { $0.name.lowercased() == "$skiptoken" })?.value,
                  !token.isEmpty else {
                found.stopped = "Azure gave a next page without a $skipToken, which Pion does not follow"
                break
            }
            query["$skipToken"] = token
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped { return "\nStopped early reading \(name): \(reason), so results may be incomplete." }
        return listing.more ? "\nStopped early reading \(name) after \(listing.pages) pages; more pages remain, so results may be incomplete." : ""
    }

    // MARK: Refusals

    /// What one thing the tool reads needs, to say exactly what to change when Azure refuses it.
    struct Need: Sendable {
        let title: String, role: String
        var scope = "the subscription"

        static let activity = Need(title: "Activity log", role: "Reader")
        static let directory = Need(title: "Directory activity log", role: "Monitoring Reader", scope: "the root scope (/), which a Global Administrator who has elevated access can give")
        static let alerts = Need(title: "Defender for Cloud alerts", role: "Security Reader")
        static let plans = Need(title: "Defender for Cloud plans", role: "Security Reader")
        static let graph = Need(title: "Resource Graph", role: "Reader")
        static let roles = Need(title: "Role assignments", role: "Reader")
        static let eligible = Need(title: "Roles eligible through Privileged Identity Management", role: "Reader")
        static let deny = Need(title: "Deny assignments", role: "Reader")
    }

    /// What to change when Azure refused something, from what it said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        let said: String
        switch error {
        case ServiceError.rejected(let reason):
            let lower = reason?.lowercased() ?? ""
            if lower.contains("invalidauthenticationtokentenant") || lower.contains("wrong issuer") {
                return "the subscription is not in the directory this connection signs in to: check the Directory (tenant) ID and Subscription ID in Settings › Tools."
            }
            return "Azure did not accept the app's sign-in: check the Directory (tenant) ID, Application (client) ID and client secret, which may have expired, in Settings › Tools."
        case ServiceError.forbidden:
            return "the app may not read this: give it \(need.role) on \(need.scope) in the Azure portal's Access control (IAM), then allow a few minutes for it to apply."
        case ServiceError.refused(let reason): said = reason
        case ServiceError.status(_, let reason): said = reason ?? ""
        default: return nil
        }
        let lower = said.lowercased()
        if lower.contains("missingsubscriptionregistration") || lower.contains("not registered to use namespace") {
            return "the subscription is not registered for this service's resource provider: someone with Contributor registers it under the subscription's Resource providers."
        }
        if lower.contains("subscriptionnotfound") || lower.contains("could not be found") && lower.contains("subscription") {
            return "Azure does not know this subscription: check the Subscription ID in Settings › Tools."
        }
        return nil
    }

    /// A request, with Azure's refusal said as what to change, so an agent can tell the champion.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason), ServiceError.status(_, let reason): reason
            case ServiceError.refused(let reason): reason
            default: nil
            }
            throw ServiceError.input("Azure refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Defender for Cloud

    struct Alert: Codable {
        struct Properties: Codable {
            struct Resource: Codable { let azureResourceId: String?, type: String? }
            struct Entity: Codable { let name: String?, type: String? }
            let alertDisplayName: String?, severity: String?, status: String?, timeGeneratedUtc: String?, processingEndTimeUtc: String?
            let startTimeUtc: String?, description: String?, entities: [Entity]?
            let compromisedEntity: String?, resourceIdentifiers: [Resource]?, techniques: [String]?, intent: String?, alertUri: String?
        }
        let id: String, name: String?, properties: Properties?

        /// When it reached Defender for Cloud: the later of when it was made and when its processing ended, so one
        /// Azure lists late is still within the window the watch reads.
        var time: Date? {
            [properties?.timeGeneratedUtc, properties?.processingEndTimeUtc].compactMap { ServiceAlert.time($0) }.max()
        }
        /// Not yet resolved or dismissed.
        var open: Bool { !["resolved", "dismissed"].contains(properties?.status?.lowercased() ?? "") }
    }

    /// Every alert of the subscription: Azure's alert listing takes no filter, so it is filtered after reading.
    static func alerts(_ service: ServiceClient) async throws -> Listing<Alert> {
        try await read(.alerts) {
            try await list(service, path: path(service, "Microsoft.Security", "alerts"), query: ["api-version": alertsVersion], as: Alert.self)
        }
    }

    struct Pricing: Decodable {
        struct Properties: Decodable { let pricingTier: String?, subPlan: String?, deprecated: Bool? }
        let name: String; let properties: Properties?
    }

    /// The Defender plans that are on and raise threat alerts, and those that are off. Defender CSPM, CloudPosture,
    /// finds misconfigurations, not threats, so it is left out.
    static func plans(_ service: ServiceClient) async throws -> (on: [String], off: [String]) {
        let plans = try await read(.plans) {
            try await service.get(path(service, "Microsoft.Security", "pricings"), query: ["api-version": pricingsVersion], as: List<Pricing>.self).value
        }.filter { $0.properties?.deprecated != true && $0.name != "CloudPosture" }
        let on = plans.filter { $0.properties?.pricingTier?.lowercased() == "standard" }
        return (on.map { $0.name + ($0.properties?.subPlan.map { " (\($0))" } ?? "") }, plans.filter { $0.properties?.pricingTier?.lowercased() != "standard" }.map(\.name))
    }
}

extension Azure {
    struct ActivityLog: ServiceOperation {
        struct Input: Decodable, Sendable {
            let caller: String?, resourceGroup: String?, resource: String?, resourceProvider: String?, correlationId: String?, operation: String?
            let failuresOnly: Bool?, since: String?, until: String?, limit: Int?
        }
        static let name = "activity-log"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Subscription activity log events, newest first, by time, caller, one of resource group, resource, resource provider or correlation ID, operation and outcome, with each event's caller IP, claims, the permission it used and its correlation ID, saying when it stopped before reading everything."
        static let input = JSONSchema.object([
            "caller": .string("Only this caller: a user's sign-in name or an app's ID, as the log records it."),
            "resourceGroup": .string("Only this resource group."),
            "resource": .string("Only this resource, by its full ID, such as /subscriptions/…/resourceGroups/…/providers/Microsoft.Compute/virtualMachines/vm-one."),
            "resourceProvider": .string("Only this resource provider, such as Microsoft.Authorization or Microsoft.Compute."),
            "correlationId": .string("Only the events of one request, by its correlation ID, a GUID."),
            "operation": .string("Only operations whose name holds this, such as Microsoft.Authorization/roleAssignments/write or runCommand. Matched by Pion as it reads, as Azure cannot filter on it."),
            "failuresOnly": .boolean("Only failed activity."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ])

        static let select = "eventDataId,eventTimestamp,caller,resourceId,resourceGroupName,resourceProviderName,status,subStatus,operationName,category,level,correlationId,httpRequest,claims,authorization"
        /// The claims kept, by the names they are kept under: who, from where and through which app, never a token.
        static let claims = ["appid": "appid", "ipaddr": "ipaddr", "name": "name", "idtyp": "idtyp",
                             "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn": "upn",
                             "http://schemas.microsoft.com/identity/claims/objectidentifier": "oid"]

        struct Named: Codable { let value: String?, localizedValue: String? }
        struct Request: Codable { let clientIpAddress: String?, method: String? }
        struct Authorization: Codable { let action: String?, scope: String? }
        struct Event: Decodable {
            let eventDataId: String?, eventTimestamp: String?, caller: String?, resourceId: String?, resourceGroupName: String?
            let status: Named?, subStatus: Named?, operationName: Named?, category: Named?, level: String?, correlationId: String?
            let httpRequest: Request?, authorization: Authorization?, claims: [String: GoogleCloud.JSON]?
        }
        struct Kept: Encodable {
            let eventDataId: String?, eventTimestamp: String?, caller: String?, callerIp: String?, claims: [String: String]
            let operation: String?, action: String?, status: String?, subStatus: String?, category: String?, level: String?
            let correlationId: String?, resourceId: String?, resourceGroupName: String?

            init(_ event: Event) {
                eventDataId = event.eventDataId; eventTimestamp = event.eventTimestamp; caller = event.caller
                callerIp = event.httpRequest?.clientIpAddress ?? event.claims?["ipaddr"]?.text
                var kept: [String: String] = [:]
                for (claim, name) in ActivityLog.claims { if let value = event.claims?[claim]?.text { kept[name] = value } }
                claims = kept
                operation = event.operationName?.value; action = event.authorization?.action
                status = event.status?.value; subStatus = event.subStatus?.value.flatMap { $0.isEmpty ? nil : $0 }
                category = event.category?.value; level = event.level; correlationId = event.correlationId
                resourceId = event.resourceId; resourceGroupName = event.resourceGroupName
            }
        }

        /// The window, checked: since before until, both within the 90 days the activity log keeps.
        static func window(_ since: String?, _ until: String?, days: Double = 7) throws -> (since: String, until: String) {
            let since = try since.map { try ServiceInput.time(ServiceInput.quoted($0, "the time")) } ?? ServiceInput.daysAgo(days)
            let until = try until.map { try ServiceInput.time(ServiceInput.quoted($0, "the time")) } ?? ISO8601DateFormatter().string(from: Date())
            guard let from = ServiceAlert.time(since), let to = ServiceAlert.time(until), from <= to,
                  from >= Date().addingTimeInterval(-90 * 86_400 - 60), to <= Date().addingTimeInterval(60) else {
                throw ServiceError.input("Give a time range within the last 90 days, with since before until.")
            }
            return (since, until)
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            // Azure's activity log takes the time range with at most one of these, as Azure CLI sends it; caller and
            // status may be added to any of them.
            let narrowed = [("resourceGroup", input.resourceGroup), ("resource", input.resource), ("resourceProvider", input.resourceProvider),
                            ("correlationId", input.correlationId)].filter { $0.1 != nil }.map(\.0)
            guard narrowed.count <= 1 else {
                throw ServiceError.input("Azure's activity log takes one of resourceGroup, resource, resourceProvider and correlationId at a time, with the time range and optionally caller and failuresOnly; give only one of \(narrowed.joined(separator: " and ")).")
            }
            let (since, until) = try Self.window(input.since, input.until)
            let limit = Int(try Graph.limit(input.limit, default: 25, maximum: 100))!
            var filter = ["eventTimestamp ge '\(since)'", "eventTimestamp le '\(until)'"]
            if let caller = input.caller { filter.append("caller eq '\(try ServiceInput.quoted(caller, "caller"))'") }
            if let group = input.resourceGroup { filter.append("resourceGroupName eq '\(try ServiceInput.quoted(group, "resourceGroup"))'") }
            if let resource = input.resource {
                filter.append("resourceUri eq '/\(try Azure.resource(resource, service).joined(separator: "/"))'")
            }
            if let provider = input.resourceProvider {
                let value = provider.trimmingCharacters(in: .whitespaces)
                guard value.count <= 100, value.range(of: #"^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$"#, options: .regularExpression) != nil else {
                    throw ServiceError.input("Give resourceProvider as a namespace, such as Microsoft.Compute.")
                }
                filter.append("resourceProvider eq '\(value)'")
            }
            if let correlation = input.correlationId { filter.append("correlationId eq '\(try Azure.guid(correlation.trimmingCharacters(in: .whitespaces)))'") }
            if input.failuresOnly == true { filter.append("status eq 'Failed'") }
            let operation = try input.operation.map { try ServiceInput.quoted($0, "operation").lowercased() }
            let listing = try await Azure.read(.activity) {
                try await Azure.list(service, path: Azure.path(service, "Microsoft.Insights", "eventtypes") + ["management", "values"],
                                     query: ["api-version": Azure.activityVersion, "$filter": filter.joined(separator: " and "), "$select": Self.select],
                                     as: Event.self, limit: limit, matching: { event in
                    (input.failuresOnly != true || event.status?.value?.lowercased() == "failed")
                        && (operation.map { (event.operationName?.value?.lowercased() ?? "").contains($0) } ?? true)
                })
            }
            let sorted = listing.value.sorted { (ServiceAlert.time($0.eventTimestamp) ?? .distantPast) > (ServiceAlert.time($1.eventTimestamp) ?? .distantPast) }
            let events = Array(sorted.prefix(limit)).map(Kept.init)
            var lines = events.isEmpty ? ["No activity matches in what was read, from \(since) to \(until)."] : events.map { event in
                var line = "\(event.eventTimestamp ?? "?") \(event.status ?? "?")\(event.subStatus.map { " (\($0))" } ?? ""): \(event.operation ?? "?") — \(event.caller ?? "?")"
                if let ip = event.callerIp { line += " from \(ip)" }
                if let resource = event.resourceId { line += " on \(resource)" }
                if let correlation = event.correlationId { line += " [correlation \(correlation)]" }
                return line
            }
            if sorted.count > events.count { lines.append("\(sorted.count) matched in what was read; the newest \(events.count) are kept.") }
            if operation != nil {
                lines.append("The operation was matched by Pion in the \(listing.read) events read over \(listing.pages) page\(listing.pages == 1 ? "" : "s"), as Azure cannot filter on it\(listing.more ? "; narrow the time or add resourceProvider to read further back" : "").")
            }
            struct Answer: Encodable { let events: [Kept]; let read: Int; let pages: Int; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + Azure.stopped(listing, "activity"),
                                     structured: Answer(events: events, read: listing.read, pages: listing.pages, complete: !listing.more))
        }
    }

    struct DefenderAlerts: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, since: String?, limit: Int? }
        static let name = "defender-alerts"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Microsoft Defender for Cloud alerts, newest first, by severity, status and time, with their entities, techniques and evidence."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: ["Informational", "Low", "Medium", "High"]),
            "status": .string("The status.", oneOf: ["Active", "InProgress", "Resolved", "Dismissed"]),
            "since": .string("The earliest creation time, in ISO 8601. The last 7 days when left out."),
            "limit": .integer("How many alerts, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severity = try input.severity.map { try ServiceInput.oneOf($0, ["Informational", "Low", "Medium", "High"], "severity") }
            let status = try input.status.map { try ServiceInput.oneOf($0, ["Active", "InProgress", "Resolved", "Dismissed"], "status") }
            let since = ServiceAlert.time(try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7))!
            let limit = Int(try Graph.limit(input.limit, default: 25, maximum: 100))!
            let listing = try await Azure.alerts(service)
            let made = { (alert: Alert) in ServiceAlert.time(alert.properties?.timeGeneratedUtc) }
            let matched = listing.value.filter { alert in
                guard let time = made(alert), time >= since else { return false }
                return (severity == nil || alert.properties?.severity == severity) && (status == nil || alert.properties?.status == status)
            }.sorted { (made($0) ?? .distantPast) > (made($1) ?? .distantPast) }
            let alerts = Array(matched.prefix(limit))
            var lines = alerts.isEmpty
                ? ["No alerts match in what was read. Defender for Cloud raises threat alerts only for the plans turned on, which check-access lists."]
                : alerts.map {
                    "\($0.properties?.timeGeneratedUtc ?? "?") \($0.properties?.severity ?? "?") \($0.properties?.status ?? "?"): \($0.properties?.alertDisplayName ?? $0.id) — \($0.properties?.compromisedEntity ?? "?") [\($0.id)]"
                }
            if matched.count > alerts.count { lines.append("\(matched.count) matched in what was read; the newest \(alerts.count) are kept.") }
            struct Kept: Encodable { let alerts: [Alert]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + Azure.stopped(listing, "alerts"), structured: Kept(alerts: alerts, complete: !listing.more))
        }
    }

    struct ResourceGraph: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "resource-graph"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Run a KQL query over the subscription's resources and return its columns and rows, saying when more matched than were read. Read-only."
        static let input = JSONSchema.object(["query": .string("The KQL query. End with take or summarize to keep results small.")], required: ["query"])

        struct Options: Encodable {
            let resultFormat = "table"; let top: Int; let skipToken: String?
            enum CodingKeys: String, CodingKey { case resultFormat, top = "$top", skipToken = "$skipToken" }
        }
        struct Body: Encodable { let subscriptions: [String]; let query: String; let options: Options }
        struct Column: Decodable { let name: String }
        struct Table: Decodable { let columns: [Column]; let rows: [[CellValue]] }
        struct Answer: Decodable {
            let totalRecords: Int?, resultTruncated: String?, skipToken: String?, data: Table
            enum CodingKeys: String, CodingKey { case totalRecords, resultTruncated, skipToken = "$skipToken", data }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let subscription = try Azure.subscription(service)
            let query = try ServiceInput.query(input.query)
            var columns: [String] = [], rows: [[CellValue]] = [], token: String?, pages = 0, total: Int?, truncated = false
            repeat {
                let answer = try await Azure.read(.graph) {
                    try await service.post(["providers", "Microsoft.ResourceGraph", "resources"],
                                           body: Body(subscriptions: [subscription], query: query, options: Options(top: 1000, skipToken: token)),
                                           query: ["api-version": Azure.graphVersion], as: Answer.self)
                }
                pages += 1
                if columns.isEmpty { columns = answer.data.columns.map(\.name) }
                rows += answer.data.rows
                total = answer.totalRecords ?? total
                truncated = truncated || answer.resultTruncated?.lowercased() == "true"
                token = answer.skipToken.flatMap { $0.isEmpty ? nil : $0 }
            } while token != nil && rows.count < Azure.graphRows && pages < Azure.graphPages
            var notice = ""
            if let total, total > rows.count {
                notice += "\nResource Graph matched \(total) rows; \(rows.count) were read. Summarize, filter or project fewer rows to see the rest."
            } else if token != nil {
                notice += "\nMore rows remain than the \(rows.count) read. Summarize, filter or project fewer rows to see the rest."
            }
            if truncated { notice += "\nAzure cut the result short and could not page it, so rows past those returned are missing: order the query and use take, or summarize." }
            return try ServiceTable(columns: columns, rows: rows).result().adding(notice)
        }
    }

    struct RoleAssignments: ServiceOperation {
        struct Input: Decodable, Sendable { let principalId: String?, atScope: Bool? }
        static let name = "role-assignments"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who has access to the subscription, with each assignment's role name and scope, and the roles eligible through Privileged Identity Management, saying what it does not cover."
        static let input = JSONSchema.object([
            "principalId": .string("Only this principal's object ID."),
            "atScope": .boolean("Only assignments at the subscription's scope or above."),
        ])

        struct Properties: Codable { let principalId: String?, principalType: String?, roleDefinitionId: String?, scope: String?, memberType: String?, endDateTime: String? }
        struct Assignment: Codable { let id: String; let properties: Properties }
        struct Definition: Decodable {
            struct Properties: Decodable { let roleName: String?, type: String? }
            let id: String; let properties: Properties
        }

        static let uncovered = "Not covered: who is in a group given access, as the group is shown, not its members (Microsoft Entra ID lists a user's groups); classic subscription administrators; and Microsoft Entra roles, such as a Global Administrator who can elevate access to every subscription. deny-assignments lists what is denied."

        static func roleKey(_ id: String) -> String { String(id.split(separator: "/").last ?? "").lowercased() }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard input.principalId == nil || input.atScope != true else { throw ServiceError.input("Give a principalId or atScope, not both.") }
            var query: [String: String?] = ["api-version": Azure.authorizationVersion]
            if let principal = input.principalId { query["$filter"] = "principalId eq '\(try Azure.guid(principal))'" }
            if input.atScope == true { query["$filter"] = "atScope()" }
            let assignments = try await Azure.read(.roles) {
                try await Azure.list(service, path: Azure.path(service, "Microsoft.Authorization", "roleAssignments"), query: query, as: Assignment.self)
            }
            // Eligible roles, which Privileged Identity Management activates on request; their absence or a refusal is
            // said, not failed, as many tenants have no PIM.
            var eligibleQuery = query
            eligibleQuery["api-version"] = Azure.eligibilityVersion
            var notes: [String] = [], eligible: [Assignment] = []
            do {
                let listing = try await Azure.list(service, path: Azure.path(service, "Microsoft.Authorization", "roleEligibilityScheduleInstances"),
                                                   query: eligibleQuery, as: Assignment.self)
                eligible = listing.value
                if listing.more || listing.stopped != nil { notes.append(Azure.stopped(listing, "eligible roles").trimmingCharacters(in: .newlines)) }
            } catch {
                notes.append("Roles eligible through Privileged Identity Management could not be read, so access someone can activate is not shown: \(Azure.fix(for: error, .eligible) ?? error.localizedDescription)")
            }
            // Only the roles named, each looked up once.
            var names: [String: String] = [:], failed = 0
            let wanted = Array(Set((assignments.value + eligible).compactMap(\.properties.roleDefinitionId).map(Self.roleKey))).sorted()
            for key in wanted.prefix(Azure.definitionLookups) where UUID(uuidString: key) != nil {
                do {
                    let definition = try await service.get(Azure.path(service, "Microsoft.Authorization", "roleDefinitions") + [key],
                                                           query: ["api-version": Azure.authorizationVersion], as: Definition.self)
                    names[key] = definition.properties.roleName
                } catch {
                    failed += 1
                }
            }
            if wanted.count > Azure.definitionLookups { notes.append("Only \(Azure.definitionLookups) of \(wanted.count) roles were named; the rest show their definition ID.") }
            if failed > 0 { notes.append("\(failed) role definition\(failed == 1 ? "" : "s") could not be read and show their ID.") }
            struct Kept: Encodable { let id: String; let properties: Properties; let roleName: String?; let eligible: Bool }
            struct Answer: Encodable { let assignments: [Kept]; let complete: Bool }
            let kept = assignments.value.map { Kept(id: $0.id, properties: $0.properties, roleName: $0.properties.roleDefinitionId.flatMap { names[Self.roleKey($0)] }, eligible: false) }
                + eligible.map { Kept(id: $0.id, properties: $0.properties, roleName: $0.properties.roleDefinitionId.flatMap { names[Self.roleKey($0)] }, eligible: true) }
            let text = kept.isEmpty ? "No access matches." : kept.prefix(30).map {
                "\($0.properties.principalId ?? "?")\($0.properties.principalType.map { " (\($0))" } ?? ""): \($0.roleName ?? $0.properties.roleDefinitionId ?? "?") on \($0.properties.scope ?? "?")"
                    + ($0.eligible ? ", eligible through PIM, not active until activated" : "")
            }.joined(separator: "\n")
            let count = kept.count > 30 ? "\nShowing 30 of \(kept.count)\(assignments.more ? " read so far" : " total") assignments." : ""
            return try ServiceResult(text: text + count + Azure.stopped(assignments, "role assignments") + notes.map { "\n" + $0 }.joined() + "\n" + Self.uncovered,
                                     structured: Answer(assignments: kept, complete: !assignments.more))
        }
    }

    struct DenyAssignments: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "deny-assignments"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Deny assignments on the subscription: which actions are denied to whom, at which scope, and who is exempt."
        static let input = JSONSchema.object([:])

        struct Permission: Codable { let actions: [String]?, notActions: [String]?, dataActions: [String]? }
        struct Principal: Codable { let id: String?, type: String? }
        struct Properties: Codable {
            let denyAssignmentName: String?, scope: String?, permissions: [Permission]?, principals: [Principal]?, excludePrincipals: [Principal]?
            let isSystemProtected: Bool?, doNotApplyToChildScopes: Bool?
        }
        struct Deny: Codable { let id: String; let properties: Properties }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Azure.read(.deny) {
                try await Azure.list(service, path: Azure.path(service, "Microsoft.Authorization", "denyAssignments"),
                                     query: ["api-version": Azure.authorizationVersion], as: Deny.self)
            }
            let lines = listing.value.isEmpty ? ["No deny assignments apply."] : listing.value.prefix(30).map { deny in
                let actions = (deny.properties.permissions ?? []).flatMap { ($0.actions ?? []) + ($0.dataActions ?? []) }
                let principals = (deny.properties.principals ?? []).map { "\($0.type ?? "?") \($0.id ?? "?")" }
                let exempt = (deny.properties.excludePrincipals ?? []).map { "\($0.type ?? "?") \($0.id ?? "?")" }
                return "\(deny.properties.denyAssignmentName ?? deny.id) on \(deny.properties.scope ?? "?"): denies \(actions.prefix(5).joined(separator: ", "))\(actions.count > 5 ? " and \(actions.count - 5) more" : "") to \(principals.prefix(3).joined(separator: ", "))"
                    + (exempt.isEmpty ? "" : ", except \(exempt.prefix(3).joined(separator: ", "))") + (deny.properties.isSystemProtected == true ? " (system protected)" : "")
            }
            let more = listing.value.count > 30 ? "\nShowing 30 of \(listing.value.count)." : ""
            struct Answer: Encodable { let denyAssignments: [Deny]; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n") + more + Azure.stopped(listing, "deny assignments"),
                                     structured: Answer(denyAssignments: listing.value, complete: !listing.more))
        }
    }

    /// Tries each thing Microsoft Azure Detection reads once, says what works and what to change for what does not, which
    /// Defender plans raise alerts, and whether the app could change anything.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: a role, the subscription or tenant, or the app's secret; which Defender for Cloud plans are on, as only they raise threat alerts; whether the directory activity log, where elevated access is recorded, can be read; and whether the app could change anything. It changes nothing."
        static let input = JSONSchema.object([:])

        struct Permissions: Decodable { let actions: [String]?, notActions: [String]? }

        /// Actions that change things rather than read them: everything, everything of a service, writes and deletes.
        static func changes(_ action: String) -> Bool {
            let lower = action.lowercased()
            return lower == "*" || lower.hasSuffix("/*") || lower.hasSuffix("/write") || lower.hasSuffix("/delete")
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let subscription = try Azure.subscription(service)
            let hour = "eventTimestamp ge '\(ServiceInput.daysAgo(1.0 / 24))' and eventTimestamp le '\(ISO8601DateFormatter().string(from: Date()))'"
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(need.title)" }
                catch { return "✗ \(need.title): " + (Azure.fix(for: error, need) ?? error.localizedDescription) }
            }
            var lines: [String] = []
            lines.append(await check(.activity) {
                _ = try await service.data(Azure.path(service, "Microsoft.Insights", "eventtypes") + ["management", "values"],
                                           query: ["api-version": Azure.activityVersion, "$filter": hour, "$select": "eventDataId"])
            })
            lines.append(await check(.alerts) {
                _ = try await service.data(Azure.path(service, "Microsoft.Security", "alerts"), query: ["api-version": Azure.alertsVersion])
            })
            do {
                let plans = try await Azure.plans(service)
                lines.append(plans.on.isEmpty
                    ? "⚠ No Defender for Cloud plan that raises threat alerts is on, so its alerts stay silent whatever happens: turn on plans such as Defender for Servers, Storage or Key Vault in Defender for Cloud's Environment settings. Off: \(plans.off.joined(separator: ", "))."
                    : "✓ Defender for Cloud plans on, which raise alerts: \(plans.on.joined(separator: ", "))." + (plans.off.isEmpty ? "" : " Off, so silent: \(plans.off.joined(separator: ", ")).")
                )
            } catch {
                lines.append("✗ \(Need.plans.title): " + (Azure.fix(for: error, .plans) ?? error.localizedDescription) + " Until they can be read, no alerts means unknown.")
            }
            lines.append(await check(.graph) {
                struct Body: Encodable { let subscriptions: [String]; let query: String }
                _ = try await service.data(["providers", "Microsoft.ResourceGraph", "resources"], query: ["api-version": Azure.graphVersion], method: "POST",
                                           body: try JSONEncoder().encode(Body(subscriptions: [subscription], query: "Resources | take 1")))
            })
            lines.append(await check(.roles) {
                _ = try await service.data(Azure.path(service, "Microsoft.Authorization", "roleAssignments"),
                                           query: ["api-version": Azure.authorizationVersion, "$filter": "atScope()"])
            })
            lines.append(await check(.deny) {
                _ = try await service.data(Azure.path(service, "Microsoft.Authorization", "denyAssignments"), query: ["api-version": Azure.authorizationVersion])
            })
            do {
                _ = try await service.data(["providers", "Microsoft.Insights", "eventtypes", "management", "values"],
                                           query: ["api-version": Azure.activityVersion, "$filter": hour, "$select": "eventDataId"])
                lines.append("✓ \(Need.directory.title): readable, so the watch sees a Global Administrator elevating access.")
            } catch {
                lines.append("· \(Need.directory.title), where Azure records a Global Administrator elevating access to every subscription: not readable, so the watch cannot see that. To read it, have a Global Administrator give the app Monitoring Reader at the root scope (/). It said: \(error.localizedDescription)")
            }
            do {
                let held = try await service.get(Azure.path(service, "Microsoft.Authorization", "permissions"),
                                                 query: ["api-version": Azure.authorizationVersion], as: List<Permissions>.self).value
                let changes = Array(Set(held.flatMap { $0.actions ?? [] }.filter(Self.changes))).sorted()
                lines.append(changes.isEmpty
                    ? "✓ The app cannot change the subscription: it holds no write, delete or wildcard action there."
                    : "⚠ The app can change the subscription: it holds \(changes.prefix(5).joined(separator: ", "))\(changes.count > 5 ? " and more" : ""). Microsoft Azure Detection only reads, so give it only Reader and Security Reader; Microsoft Azure Containment has an app of its own.")
            } catch {
                lines.append("· Whether the app could change the subscription: not checked: \(error.localizedDescription)")
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
