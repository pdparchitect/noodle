import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization

/// SentinelOne Containment: responding on one console's endpoints, with a service user and token of its own whose
/// custom role holds only the actions it takes, kept apart from Detection's so the detection user stays read-only. Every action
/// that cuts an endpoint off, changes or restores a file, hides a threat, blocks a hash or starts a scan waits for the
/// champion's approval, and each says what recovering from it involves.
///
/// SentinelOne takes an action on whatever its filter matches, so Pion sends every action with a filter of exact IDs
/// alone, never a site, group or query, and only after reading each ID through that same filter and finding exactly
/// it. Its answer says only how many it affected: an action is confirmed only when that count is exactly the IDs
/// approved and reading them again shows what was asked; a count that differs, or a state that does not follow, is
/// reported unverified with the request's details. SentinelOne carries an action out when the agent next takes
/// commands, so taken is not done: a disconnect is pending until the agent reports it, and a mitigation until its
/// status says it succeeded. A blocklist entry is Pion's only by Pion's own record of what block-hash made.
extension SentinelOne {
    public static let containment = ToolDefinition(
        id: "30213216-84c2-4982-915d-eb9ca4f7c5b5", name: "SentinelOne Containment",
        summary: "Disconnect an endpoint from the network or reconnect it, kill, quarantine, release, remediate or roll back a threat, resolve threats or set their verdict, block a hash and remove what it blocked, and start a scan, in SentinelOne.",
        defaultInstructions: """
        Use SentinelOne Containment to respond on endpoints SentinelOne protects. Find the agent or threat with \
        SentinelOne Detection first, by agents, agent, threats or threat, which give their numeric IDs, then read it here \
        with agent or threat and record it as evidence before acting. disconnect-agent cuts an endpoint off the network, \
        keeping it in touch with the console, until reconnect-agent, which must be asked for explicitly. kill-threat ends \
        a threat's processes; quarantine-threat moves its file to the agent's encrypted quarantine, and \
        unquarantine-threat releases it; remediate-threat removes the threat's files and changes; rollback-threat, on \
        Windows only, also restores files the threat touched from Volume Shadow Copy, which can undo the user's own \
        changes to them. resolve-threat resolves threats, or marks them false positives, which hides them from the \
        unresolved queue. block-hash adds a SHA1 or SHA256 to one site's blocklist for one OS and gives its ID; Pion \
        keeps a record of each one it makes, and unblock-hash removes one by that ID only if the record says Pion made \
        it and SentinelOne still holds it as made. initiate-scan starts a full disk scan. All of these are held for the \
        champion's approval: give the exact agent, threat or hash, and in --approval-reason why, the expected effect \
        and how to undo it, with the Investigation as --approval-conversation. update-threat-status sets threats in \
        progress or unresolved, or a verdict other than false positive, without approval. Pion refuses a malformed ID, \
        an agent or threat it cannot read whole, one already in the state asked for or with the same action pending, \
        rollback on anything but Windows, a hash any blocklist entry already holds, and an entry it has no record of \
        making. A request taken is not a request done: poll with action-status; a result Pion could not verify is never \
        reported done and keeps the request's details. Run check-access when something is refused, and tell the \
        champion exactly what it says to change.
        """,
        iconName: "sentinelone",
        configuration: .connection(.init(endpointTemplate: "https://{console}/web/api/v2.1", fields: [consoleField],
                                         tokenHeader: "Authorization", tokenScheme: "ApiToken", adapter: "sentinelone-containment")),
        setup: containmentSetup)

    /// Containment's permissions, as the console's role editor groups them: reading what its actions read first, and
    /// each action it takes, nothing more.
    static let containmentPermissions = [
        "Endpoints: View", "Endpoints: Disconnect From Network", "Endpoints: Reconnect To Network", "Endpoints: Initiate Scan",
        "Threats: View", "Threats: Kill", "Threats: Quarantine", "Threats: Un-Quarantine", "Threats: Remediate", "Threats: Rollback",
        "Threats: Change Incident Status", "Threats: Change Analyst Verdict",
        "Blocklist: View", "Blocklist: Create", "Blocklist: Delete", "Activity: View", "Sites: View",
    ]

    static let containmentSetup = [
        "In the SentinelOne console, open **Settings › Users › Roles** and choose **New Role**. Name it Pion Containment and give it only these permissions: \(containmentPermissions.map { "**\($0)**" }.joined(separator: ", ")). Leave every other permission off, above all users, policies, exclusions, uninstalling agents and Remote Shell.",
        "Open **Settings › Users › Service Users** and choose **Actions › Create New Service User**. Name it Pion Containment, kept for this tool alone, apart from Pion Detection's, give it an expiration date, and give it the Pion Containment role at the scope agents may act on: the account, or only some sites.",
        "Copy the **API token** it shows and give it here; SentinelOne shows it only once. Pion sends it as `Authorization: ApiToken <token>`. SentinelOne offers no way to check a role's actions without trying one, so check the role's page.",
        consoleStep,
    ]

    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 2)

    // MARK: What it needs

    static let disconnectNeed = Need(title: "Disconnecting endpoints from the network", permission: "Endpoints: Disconnect From Network")
    static let reconnectNeed = Need(title: "Reconnecting endpoints to the network", permission: "Endpoints: Reconnect To Network")
    static let scanNeed = Need(title: "Starting scans", permission: "Endpoints: Initiate Scan")
    static let incidentNeed = Need(title: "Changing threats' incident status", permission: "Threats: Change Incident Status")
    static let verdictNeed = Need(title: "Changing threats' analyst verdict", permission: "Threats: Change Analyst Verdict")
    static let blocklistNeed = Need(title: "The blocklist", permission: "Blocklist: View")
    static let blockNeed = Need(title: "Adding to the blocklist", permission: "Blocklist: Create")
    static let unblockNeed = Need(title: "Removing from the blocklist", permission: "Blocklist: Delete")

    /// How long to wait between reads of something just asked for, before saying where it stands.
    @TaskLocal static var pauses: [Double] = [1, 2, 3, 5]

    static let agentField = JSONSchema.string("The agent's ID, digits only, as SentinelOne Detection's agents, agent or a threat gives it.")
    static let threatField = JSONSchema.string("The threat's ID, digits only, as SentinelOne Detection's threats gives it.")

    /// The body of every action: a filter of exact IDs and nothing else, each checked, never a site, group or query.
    static func filterBody(_ ids: [String], data: [String: String] = [:]) throws -> Data {
        guard !ids.isEmpty, ids.allSatisfy({ id($0) == $0 }), Set(ids).count == ids.count else {
            throw ServiceError.input("Nothing was changed: an action names each agent or threat by its exact ID, once.")
        }
        return try JSONSerialization.data(withJSONObject: ["filter": ["ids": ids], "data": data], options: [.sortedKeys])
    }

    /// What an action's request was, for a result that could not be verified.
    static func requested(_ path: [String], _ ids: [String], _ data: [String: String] = [:]) -> String {
        "Request: POST /web/api/v2.1/\(path.joined(separator: "/")) with filter ids [\(ids.joined(separator: ", "))]\(data.isEmpty ? "" : " and data \(data.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")."
    }

    /// Sends one action and returns how many SentinelOne said it affected, or nil when it did not say.
    static func act(_ service: ServiceClient, _ path: [String], ids: [String], data: [String: String] = [:], need: Need) async throws -> (affected: Int?, problems: String?) {
        let body = try filterBody(ids, data: data)
        struct Affected: Decodable { let affected: Int? }
        let answer = try await read(need) { try await exchange(service, path, method: "POST", body: body) }
        guard let envelope = try? JSONDecoder().decode(Single<Affected>.self, from: answer.data) else { return (nil, "an answer that could not be read") }
        return (envelope.data?.affected, envelope.problems)
    }

    /// Why an action's count is not the IDs approved, or nil when it is.
    static func countProblem(_ affected: Int?, expected: Int, problems: String?) -> String? {
        switch affected {
        case expected?: return problems.map { "SentinelOne gave errors with its count: \($0)" }
        case nil: return "SentinelOne did not say how many it affected\(problems.map { " (it said: \($0))" } ?? "")"
        case 0?: return "SentinelOne said it affected none\(problems.map { " (it said: \($0))" } ?? "")"
        case let count?: return count > expected
            ? "⚠ SentinelOne said it affected \(count), more than the \(expected) approved: check the console's activity log at once"
            : "SentinelOne said it affected \(count) of the \(expected) approved\(problems.map { " (it said: \($0))" } ?? "")"
        }
    }
}

// MARK: - Agents

extension SentinelOne {
    struct AgentTarget {
        let agent: Agent
        let readAt: String
    }

    /// Reads an agent whole through the exact-ID filter an action uses, or refuses: a malformed ID, an agent SentinelOne
    /// does not return, or an answer that shows neither.
    static func targetAgent(_ value: String, _ service: ServiceClient) async throws -> AgentTarget {
        guard let id = id(value) else { throw ServiceError.input("Nothing was changed: give the agent's ID, digits only, as SentinelOne Detection's agents, agent or a threat gives it.") }
        switch try await agent(id, service) {
        case .present(let agent): return AgentTarget(agent: agent, readAt: iso(Date()))
        case .absent: throw ServiceError.input("Nothing was changed: SentinelOne has no agent \(id) in this token's scope. It may have been removed, lie outside the service user's sites, or the ID was mistyped.")
        case .inconclusive(let why): throw ServiceError.input("Nothing was changed: agent \(id) could not be read whole first (\(why)), so the filter could not be shown to match it alone.")
        }
    }

    static func activeLine(_ agent: Agent) -> String {
        switch agent.active {
        case true?: "The agent is in touch with the console now, so it takes the action within moments."
        case false?: "The agent is not in touch with the console now, so it takes the action when it next connects; until then it is pending."
        case nil: "Whether the agent is in touch with the console was not given, so when it takes the action is unknown."
        }
    }

    struct ContainmentAgent: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "agent"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "An agent's state before acting: whether it is disconnected from the network, said plainly (pending is not done), whether it is in touch with the console, its OS, infection and scan status. It changes nothing."
        static let input = JSONSchema.object(["id": SentinelOne.agentField], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await SentinelOne.targetAgent(input.id, service)
            let agent = target.agent
            let lines = [agent.line, "Disconnect from Network: \(SentinelOne.network(agent.network)).", SentinelOne.activeLine(agent),
                         "Scan: \(agent.scanStatus ?? "status not given")\(agent.text("scanStartedAt").map { ", started \($0)" } ?? "").", "Read at \(target.readAt)."]
            struct Kept: Encodable { let agent: String; let name: String?; let network: String?; let active: Bool?; let osType: String?; let scan: String?; let readAt: String }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(agent: agent.id, name: agent.name, network: agent.network, active: agent.active, osType: agent.osType, scan: agent.scanStatus, readAt: target.readAt))
        }
    }

    /// Asks SentinelOne to disconnect an agent from the network or reconnect it, then reads it until its network status
    /// shows the request, and says where it stands.
    static func networkAction(_ action: String, _ target: AgentTarget, recovery: String, note: String?, need: Need, on service: ServiceClient) async throws -> ServiceResult {
        let id = target.agent.id
        let path = ["agents", "actions", action]
        let verb = action == "disconnect" ? "disconnect" : "reconnect"
        let (affected, problems) = try await act(service, path, ids: [id], need: need)
        if let problem = countProblem(affected, expected: 1, problems: problems) {
            throw ServiceError.input("SentinelOne took the request to \(verb) \(target.agent.named), but it could not be verified: \(problem). It is not reported done; read it with action-status.\n\(requested(path, [id]))\n\(recovery)")
        }
        let pending = action == "disconnect" ? "disconnecting" : "connecting"
        let done = action == "disconnect" ? "disconnected" : "connected"
        var status: String?, unread: String?, waited = 0.0
        for pause in pauses {
            await SentinelOne.pause(pause)
            waited += pause
            switch try? await agent(id, service) {
            case .present(let agent)?: status = agent.network; unread = nil
            case .absent?: unread = "SentinelOne no longer returned the agent"
            case .inconclusive(let why)?: unread = why
            case nil: unread = "reading the agent again failed"
            }
            if status == done { break }
        }
        guard status == pending || status == done else {
            let why = unread.map { "reading the agent again: \($0)" } ?? "its network status after \(Int(waited)) seconds is \(network(status))"
            throw ServiceError.input("SentinelOne said it affected the agent, but the request to \(verb) \(target.agent.named) could not be verified: \(why). It is not reported done; read it with action-status.\n\(requested(path, [id]))\n\(recovery)")
        }
        var lines = ["Asked SentinelOne to \(verb) \(target.agent.named): it said it affected exactly that one agent, and after \(Int(waited)) seconds its network status is \(network(status))."]
        let known = ["connected", "connecting", "disconnected", "disconnecting"].contains(target.agent.network ?? "")
        if !known { lines.append("Its network status before was \(network(target.agent.network)), so that it is now \(status!) is confirmed, but not that this request, rather than an earlier one, brought it about.") }
        if status == pending { lines.append("Pending is not done: the agent carries it out when it next takes commands. Poll with action-status until the status is \(done).") }
        lines.append(activeLine(target.agent))
        if let note { lines.append(note) }
        lines.append(recovery)
        lines.append("\(target.agent.named) was read at \(target.readAt). SentinelOne takes no condition on the request, so someone else may have acted on it between that read and this request.")
        struct Kept: Encodable { let agent: String; let action: String; let network: String?; let before: String?; let done: Bool; let recovery: String }
        return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(agent: id, action: action, network: status, before: known ? target.agent.network : nil, done: status == done, recovery: recovery))
    }

    struct DisconnectAgent: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "disconnect-agent"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: reconnect-agent restores the endpoint's network access, and must be asked for explicitly; until then it reaches only the SentinelOne console, so its user cannot work on it and every workload on it is cut off too."
        static let summary = "Disconnect one endpoint from the network by its agent's ID, keeping it in touch with the SentinelOne console. Sent with a filter of that ID alone, and confirmed only when SentinelOne says it affected exactly one agent and the agent's status then follows. \(recovery)"
        static let input = JSONSchema.object(["id": SentinelOne.agentField], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await SentinelOne.targetAgent(input.id, service)
            switch target.agent.network {
            case "disconnected": throw ServiceError.input("Nothing was changed: \(target.agent.named) is already disconnected from the network. reconnect-agent reconnects it.")
            case "disconnecting": throw ServiceError.input("Nothing was changed: a disconnect of \(target.agent.named) is already pending; poll it with action-status.")
            case "connecting": throw ServiceError.input("Nothing was changed: a reconnect of \(target.agent.named) is pending, and the two would race. Wait for it with action-status.")
            default: break
            }
            let note = target.agent.network == "connected" ? nil : "Its network status before this was \(SentinelOne.network(target.agent.network)), so whether it was already disconnected could not be confirmed."
            return try await SentinelOne.networkAction("disconnect", target, recovery: Self.recovery, note: note, need: SentinelOne.disconnectNeed, on: service)
        }
    }

    struct ReconnectAgent: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "reconnect-agent"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: disconnect-agent again. Reconnecting restores the endpoint's full network access, an attacker's still on it included, so reconnect it only once the champion judges it clean."
        static let summary = "Reconnect one endpoint to the network by its agent's ID. Held like the rest, as it gives access back. \(recovery)"
        static let input = JSONSchema.object(["id": SentinelOne.agentField], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await SentinelOne.targetAgent(input.id, service)
            switch target.agent.network {
            case "connected": throw ServiceError.input("Nothing was changed: \(target.agent.named) is not disconnected from the network, so there is nothing to reconnect.")
            case "connecting": throw ServiceError.input("Nothing was changed: a reconnect of \(target.agent.named) is already pending; poll it with action-status.")
            case "disconnecting": throw ServiceError.input("Nothing was changed: a disconnect of \(target.agent.named) is still pending, and the two would race. Wait for it with action-status.")
            default: break
            }
            let note = target.agent.network == "disconnected" ? nil : "Its network status before this was \(SentinelOne.network(target.agent.network)), so whether it was disconnected could not be confirmed."
            return try await SentinelOne.networkAction("connect", target, recovery: Self.recovery, note: note, need: SentinelOne.reconnectNeed, on: service)
        }
    }

    struct InitiateScan: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "initiate-scan"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: none needed: a scan changes nothing by itself, but a full disk scan uses the endpoint's CPU and disk until it ends, and what it finds is handled as the agent's policy says. Abort it in the console (Actions › Abort Scan) if it gets in the user's way."
        static let summary = "Start a full disk scan on one endpoint by its agent's ID. Held, as it is a change that uses the endpoint's resources. \(recovery)"
        static let input = JSONSchema.object(["id": SentinelOne.agentField], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await SentinelOne.targetAgent(input.id, service)
            let id = target.agent.id
            if target.agent.scanStatus == "started" {
                throw ServiceError.input("Nothing was changed: \(target.agent.named) is already scanning, started \(target.agent.text("scanStartedAt") ?? "at a time not given"); poll it with action-status.")
            }
            let path = ["agents", "actions", "initiate-scan"]
            let asked = Date()
            let (affected, problems) = try await SentinelOne.act(service, path, ids: [id], need: SentinelOne.scanNeed)
            if let problem = SentinelOne.countProblem(affected, expected: 1, problems: problems) {
                throw ServiceError.input("SentinelOne took the request to scan \(target.agent.named), but it could not be verified: \(problem). It is not reported started.\n\(SentinelOne.requested(path, [id]))\n\(Self.recovery)")
            }
            var started: String?
            for pause in SentinelOne.pauses {
                await SentinelOne.pause(pause)
                if case .present(let agent)? = try? await SentinelOne.agent(id, service), agent.scanStatus == "started" || agent.scanStatus == "finished",
                   let time = ServiceAlert.time(agent.text("scanStartedAt")), time >= asked.addingTimeInterval(-120) {
                    started = "\(agent.scanStatus!) (started \(SentinelOne.iso(time)))"
                    break
                }
            }
            let lines = [started.map { "Asked SentinelOne to scan \(target.agent.named): it said it affected exactly that one agent, and the agent's scan status is now \($0)." }
                             ?? "Asked SentinelOne to scan \(target.agent.named): it said it affected exactly that one agent, but the agent does not show the scan started yet, so it is pending, not done. Poll with action-status.",
                         SentinelOne.activeLine(target.agent), Self.recovery]
            struct Kept: Encodable { let agent: String; let started: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(agent: id, started: started != nil, recovery: Self.recovery))
        }
    }
}

// MARK: - Threats

extension SentinelOne {
    struct ThreatTarget {
        let threat: Threat
        let readAt: String
    }

    static func targetThreat(_ value: String, _ service: ServiceClient) async throws -> ThreatTarget {
        guard let id = id(value) else { throw ServiceError.input("Nothing was changed: give the threat's ID, digits only, as SentinelOne Detection's threats gives it.") }
        switch try await threat(id, service) {
        case .present(let threat): return ThreatTarget(threat: threat, readAt: iso(Date()))
        case .absent: throw ServiceError.input("Nothing was changed: SentinelOne has no threat \(id) in this token's scope. It may have been deleted, lie outside the service user's sites, or the ID was mistyped.")
        case .inconclusive(let why): throw ServiceError.input("Nothing was changed: threat \(id) could not be read whole first (\(why)), so the filter could not be shown to match it alone.")
        }
    }

    /// The times the threat's mitigation history says an action succeeded; nil for one without a time.
    static func successes(_ threat: Threat, _ kind: String) -> [Date?] {
        (threat.mitigations ?? []).filter { $0.kind == kind && $0.outcome == .done }.map { ServiceAlert.time($0.time) }
    }

    /// Whether the history shows the threat in the state `kind` leaves it in, against `inverse`, which undoes it: true,
    /// false, or nil when the history cannot tell, as when it was not given or a time is missing.
    static func inState(_ threat: Threat, _ kind: String, undoneBy inverse: String?) -> Bool? {
        guard threat.mitigations != nil else { return nil }
        let done = successes(threat, kind)
        if done.isEmpty { return false }
        guard let inverse else { return true }
        let undone = successes(threat, inverse)
        if undone.isEmpty { return true }
        guard done.allSatisfy({ $0 != nil }), undone.allSatisfy({ $0 != nil }), let last = done.compactMap({ $0 }).max(), let lastUndone = undone.compactMap({ $0 }).max() else { return nil }
        return last > lastUndone
    }

    struct ContainmentThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "A threat's state before acting: its endpoint and OS (rollback needs Windows), incident status, analyst verdict, mitigation status, and every mitigation action with where it stands (pending is not done). It changes nothing."
        static let input = JSONSchema.object(["id": SentinelOne.threatField], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let target = try await SentinelOne.targetThreat(input.id, service)
            let threat = target.threat
            let history = threat.mitigations.map { $0.isEmpty ? "none listed" : $0.map(\.line).joined(separator: "; ") } ?? "not given, so unknown"
            let quarantined = SentinelOne.inState(threat, "quarantine", undoneBy: "un-quarantine")
            let lines = [threat.line, "Endpoint \(threat.computer ?? "not given") [agent \(threat.agentID ?? "not given")], OS \(threat.osType ?? "not given")\(threat.osType == "windows" ? "" : "; rollback-threat needs Windows").",
                         "Mitigation actions: \(history).",
                         "Quarantined: \(quarantined.map { $0 ? "yes, per its mitigation history" : "no, per its mitigation history" } ?? "cannot be told from its mitigation history").",
                         "Read at \(target.readAt)."]
            struct Kept: Encodable { let threat: String; let agent: String?; let osType: String?; let incidentStatus: String?; let verdict: String?; let mitigations: [String]?; let quarantined: Bool?; let readAt: String }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(threat: threat.id, agent: threat.agentID, osType: threat.osType, incidentStatus: threat.incidentStatus, verdict: threat.verdict,
                                                      mitigations: threat.mitigations?.map(\.line), quarantined: quarantined, readAt: target.readAt))
        }
    }

    /// A mitigation action: its path, as Pion names it, what undoes it, and whether it leaves a state an action asked
    /// again finds already in force.
    struct Mitigation: Sendable {
        let action: String
        let verb: String
        /// The role permission it takes, as containmentPermissions names it.
        let permission: String
        let undoneBy: String?
        let keepsState: Bool
        let recovery: String
    }

    /// Reads the threat whole, refuses an action already pending or a state already in force, sends the action for that
    /// threat alone, then reads it again until its history shows a new record of the action, and says where it stands.
    static func mitigate(_ mitigation: Mitigation, _ value: String, on service: ServiceClient) async throws -> ServiceResult {
        let target = try await targetThreat(value, service)
        let threat = target.threat
        if mitigation.action == "rollback-remediation", threat.osType != "windows" {
            throw ServiceError.input("Nothing was changed: rollback works only on Windows, and \(threat.osType.map { "threat \(threat.id) is on \($0)" } ?? "the threat's OS was not given, so Windows could not be confirmed"). remediate-threat removes it without restoring files.")
        }
        var notes: [String] = []
        if let history = threat.mitigations {
            if history.contains(where: { $0.kind == mitigation.action && $0.outcome == .pending }) {
                throw ServiceError.input("Nothing was changed: \(mitigation.verb) of threat \(threat.id) is already pending, per its mitigation history; poll it with action-status.")
            }
            if mitigation.action == "un-quarantine" {
                switch inState(threat, "quarantine", undoneBy: "un-quarantine") {
                case false?: throw ServiceError.input("Nothing was changed: threat \(threat.id) is not quarantined, per its mitigation history, so there is nothing to release.")
                case nil: notes.append("Whether it is quarantined could not be told from its mitigation history, so whether it was already released could not be confirmed.")
                case true?: break
                }
            } else if mitigation.keepsState {
                switch inState(threat, mitigation.action, undoneBy: mitigation.undoneBy) {
                case true?: throw ServiceError.input("Nothing was changed: threat \(threat.id) is already through \(mitigation.verb), per its mitigation history: \(history.filter { $0.kind == mitigation.action }.map(\.line).joined(separator: "; ")).")
                case nil: notes.append("Whether \(mitigation.verb) was already done could not be told from its mitigation history.")
                case false?: break
                }
            }
        } else {
            notes.append("SentinelOne gave no mitigation history for it, so whether \(mitigation.verb) was already done or pending could not be confirmed.")
        }
        // What the history held of this action before, or nil when it was not given: then nothing is known to be old,
        // and only a record dated at or after the request counts as this request's.
        let before = threat.mitigations.map { Set($0.filter { $0.kind == mitigation.action }.map(\.signature)) }
        let asked = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let path = ["threats", "mitigate", mitigation.action]
        let need = Need(title: "Threats' \(mitigation.verb)", permission: mitigation.permission)
        let (affected, problems) = try await act(service, path, ids: [threat.id], need: need)
        if let problem = countProblem(affected, expected: 1, problems: problems) {
            throw ServiceError.input("SentinelOne took the request for \(mitigation.verb) of threat \(threat.id), but it could not be verified: \(problem). It is not reported done; read it with action-status.\n\(requested(path, [threat.id]))\n\(mitigation.recovery)")
        }
        var latest: Threat.Mitigation?, unread: String?, waited = 0.0
        for pause in pauses {
            await SentinelOne.pause(pause)
            waited += pause
            switch try? await SentinelOne.threat(threat.id, service) {
            case .present(let now)?:
                unread = nil
                latest = (now.mitigations ?? []).filter { record in
                    guard record.kind == mitigation.action else { return false }
                    if let before { return !before.contains(record.signature) }
                    return ServiceAlert.time(record.time).map { $0 >= asked } ?? false
                }.last
            case .absent?: unread = "SentinelOne no longer returned the threat"
            case .inconclusive(let why)?: unread = why
            case nil: unread = "reading the threat again failed"
            }
            if let outcome = latest?.outcome, outcome == .done || outcome == .failed { break }
        }
        let where_ = "on \(threat.computer ?? "an endpoint not named") [agent \(threat.agentID ?? "not given")]"
        switch latest?.outcome {
        case .done?:
            break
        case .pending?:
            break
        case .failed?:
            throw ServiceError.input("SentinelOne took \(mitigation.verb) of threat \(threat.id) \(where_), and its mitigation history now says it failed: \(latest!.line). It is not done.\n\(requested(path, [threat.id]))\n\(mitigation.recovery)")
        default:
            let why = unread.map { "reading the threat again: \($0)" } ?? (latest.map { "its new record says \($0.line), which Pion does not read as done, pending or failed" }
                ?? (before == nil ? "its history before was not given, and after \(Int(waited)) seconds it shows no record of \(mitigation.verb) dated at or after the request (\(iso(asked)))" : "its mitigation history shows no new record of it after \(Int(waited)) seconds"))
            throw ServiceError.input("SentinelOne said it affected the threat, but \(mitigation.verb) of threat \(threat.id) \(where_) could not be verified: \(why). It is not reported done; read it with action-status.\n\(requested(path, [threat.id]))\n\(mitigation.recovery)")
        }
        let done = latest?.outcome == .done
        var lines = ["Asked SentinelOne for \(mitigation.verb) of threat \(threat.id), \(threat.title), \(where_): it said it affected exactly that one threat, and its mitigation history now says \(latest!.line)."]
        if !done { lines.append("Pending is not done: the agent carries it out when it next takes commands. Poll with action-status.") }
        lines += notes
        lines.append(mitigation.recovery)
        lines.append("Threat \(threat.id) was read at \(target.readAt). SentinelOne takes no condition on the request, so someone else may have acted on it between that read and this request.")
        struct Kept: Encodable { let threat: String; let action: String; let status: String?; let done: Bool; let recovery: String }
        return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(threat: threat.id, action: mitigation.action, status: latest?.status, done: done, recovery: mitigation.recovery))
    }

    static let threatInput = JSONSchema.object(["id": threatField], required: ["id"])

    struct KillThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "kill-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let mitigation = Mitigation(action: "kill", verb: "kill", permission: "Threats: Kill", undoneBy: nil, keepsState: false,
                                           recovery: "Recovery: none: the threat's processes are ended, and their memory and unsaved work are gone for good, so record what they were first; a process can only be started again, and a service may restart itself.")
        static let summary = "Kill one threat's processes on its endpoint, by the threat's ID. \(mitigation.recovery)"
        static let input = SentinelOne.threatInput
        static let readOnly = false
        static let destructive = true
        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult { try await SentinelOne.mitigate(Self.mitigation, input.id, on: service) }
    }

    struct QuarantineThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "quarantine-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let mitigation = Mitigation(action: "quarantine", verb: "quarantine", permission: "Threats: Quarantine", undoneBy: "un-quarantine", keepsState: true,
                                           recovery: "Recovery: unquarantine-threat restores the file to where it was. Quarantining moves it into the agent's encrypted quarantine, so it can no longer run, and kills its processes first.")
        static let summary = "Quarantine one threat's file on its endpoint, by the threat's ID. \(mitigation.recovery)"
        static let input = SentinelOne.threatInput
        static let readOnly = false
        static let destructive = true
        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult { try await SentinelOne.mitigate(Self.mitigation, input.id, on: service) }
    }

    struct UnquarantineThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "unquarantine-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let mitigation = Mitigation(action: "un-quarantine", verb: "release from quarantine", permission: "Threats: Un-Quarantine", undoneBy: nil, keepsState: false,
                                           recovery: "Recovery: quarantine-threat again. Releasing restores the file to its place, where it can run again, so release only what the champion judged harmless; marking it a false positive or adding an exclusion is separate.")
        static let summary = "Release one threat's file from the agent's quarantine, restoring it, by the threat's ID; refused when its mitigation history shows it is not quarantined. \(mitigation.recovery)"
        static let input = SentinelOne.threatInput
        static let readOnly = false
        static let destructive = true
        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult { try await SentinelOne.mitigate(Self.mitigation, input.id, on: service) }
    }

    struct RemediateThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "remediate-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let mitigation = Mitigation(action: "remediate", verb: "remediation", permission: "Threats: Remediate", undoneBy: nil, keepsState: true,
                                           recovery: "Recovery: none through SentinelOne: remediation removes the threat's files and reverses the changes the agent tied to it, such as registry keys and scheduled tasks, for good.")
        static let summary = "Remediate one threat on its endpoint, by the threat's ID: kill, quarantine and remove what it changed. \(mitigation.recovery)"
        static let input = SentinelOne.threatInput
        static let readOnly = false
        static let destructive = true
        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult { try await SentinelOne.mitigate(Self.mitigation, input.id, on: service) }
    }

    struct RollbackThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "rollback-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let mitigation = Mitigation(action: "rollback-remediation", verb: "rollback", permission: "Threats: Rollback", undoneBy: nil, keepsState: true,
                                           recovery: "Recovery: none through SentinelOne: rollback, on Windows only, remediates the threat and restores the files it touched from Volume Shadow Copy snapshots taken before it, which also undoes any legitimate change the user made to those files since.")
        static let summary = "Roll back one threat on a Windows endpoint, by the threat's ID; refused on any other OS, or one not given. ⚠ It restores files and may undo the user's own changes. \(mitigation.recovery)"
        static let input = SentinelOne.threatInput
        static let readOnly = false
        static let destructive = true
        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult { try await SentinelOne.mitigate(Self.mitigation, input.id, on: service) }
    }

    /// Threats by their exact IDs, every one read whole through the filter an action uses, or a refusal.
    static func threatsByID(_ ids: [String], _ service: ServiceClient) async throws -> [Threat] {
        let listing = try await read(threatsNeed) {
            try await list(service, ["threats"], query: ["ids": ids.joined(separator: ",")], as: Threat.self, size: 100, pages: 1, partial: false)
        }
        let returned = listing.value.map(\.id)
        guard listing.complete, Set(returned) == Set(ids), returned.count == ids.count, listing.total.map({ $0 == ids.count }) ?? true else {
            let missing = ids.filter { !returned.contains($0) }, extra = returned.filter { !ids.contains($0) }
            throw ServiceError.input("Nothing was changed: the filter of these threat IDs did not read back exactly them\(missing.isEmpty ? "" : "; not returned: \(missing.joined(separator: ", "))")\(extra.isEmpty ? "" : "; also returned: \(extra.prefix(5).joined(separator: ", "))")\(listing.total.map { "; SentinelOne said \($0) match" } ?? "").")
        }
        return listing.value
    }

    /// Sets threats' verdict, incident status or both, after reading every one, then reads them again and says done only
    /// for those SentinelOne then gives with all that was asked.
    static func setThreats(_ given: [String], status: String?, verdict: String?, recovery: String, on service: ServiceClient) async throws -> ServiceResult {
        let ids = try ServiceInput.list(given, limit: 50) { value in
            guard let id = id(value) else { throw ServiceError.input("Nothing was changed: give each threat's ID, digits only, as threats lists it.") }
            return id
        }
        guard Set(ids).count == ids.count else { throw ServiceError.input("Nothing was changed: give each threat once.") }
        guard status != nil || verdict != nil else { throw ServiceError.input("Nothing was changed: give an incident status, a verdict or both.") }
        let found = try await threatsByID(ids, service)
        func matches(_ threat: Threat) -> Bool { (status == nil || threat.incidentStatus == status) && (verdict == nil || threat.verdict == verdict) }
        let already = found.filter(matches)
        guard already.isEmpty else {
            throw ServiceError.input("Nothing was changed: \(already.map(\.id).joined(separator: ", ")) \(already.count == 1 ? "is" : "are") already as asked; give only threats to change.")
        }
        let unknown = found.filter { (status != nil && $0.incidentStatus == nil) || (verdict != nil && $0.verdict == nil) }.map(\.id)
        var sent: [String] = []
        for (path, need, key, value) in [(["threats", "analyst-verdict"], verdictNeed, "analystVerdict", verdict), (["threats", "incident"], incidentNeed, "incidentStatus", status)] {
            guard let value else { continue }
            let data = [key: value]
            let (affected, problems): (Int?, String?)
            do { (affected, problems) = try await act(service, path, ids: ids, data: data, need: need) } catch {
                throw ServiceError.input("\(sent.isEmpty ? "Nothing was changed" : "Only part was sent (\(sent.joined(separator: "; ")))"): \(error.localizedDescription)\n\(requested(path, ids, data))\n\(recovery)")
            }
            if let problem = countProblem(affected, expected: ids.count, problems: problems) {
                throw ServiceError.input("SentinelOne took the request to set \(key) \(value) on \(plural(ids.count, "threat")), but it could not be verified: \(problem). It is not reported done; read them with action-status.\(sent.isEmpty ? "" : " Sent before it: \(sent.joined(separator: "; ")).")\n\(requested(path, ids, data))\n\(recovery)")
            }
            sent.append("\(key) \(value)")
        }
        await pause(pauses.first ?? 0)
        let after: [Threat]
        do { after = try await threatsByID(ids, service) } catch {
            throw ServiceError.input("SentinelOne said it changed \(plural(ids.count, "threat")) (\(sent.joined(separator: "; "))), but reading them again failed (\(error.localizedDescription)), so it could not be verified.\n\(recovery)")
        }
        let done = after.filter(matches).map(\.id)
        let notDone = ids.filter { !done.contains($0) }
        guard notDone.isEmpty else {
            throw ServiceError.input("SentinelOne said it changed \(plural(ids.count, "threat")) (\(sent.joined(separator: "; "))), but \(notDone.joined(separator: ", ")) \(notDone.count == 1 ? "is" : "are") not as asked when read again, so \(notDone.count == 1 ? "it is" : "they are") not reported done.\n\(recovery)")
        }
        var lines = ["Set \(sent.joined(separator: " and ")) on \(plural(done.count, "threat")), as SentinelOne now gives \(done.count == 1 ? "it" : "them"): \(done.joined(separator: ", "))."]
        if !unknown.isEmpty { lines.append("Before this, SentinelOne did not give the status or verdict of \(unknown.joined(separator: ", ")), so what they were could not be confirmed.") }
        lines.append(recovery)
        struct Kept: Encodable { let threats: [String]; let incidentStatus: String?; let verdict: String?; let done: Bool; let recovery: String }
        return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(threats: done, incidentStatus: status, verdict: verdict, done: true, recovery: recovery))
    }

    struct ResolveThreat: ServiceOperation {
        struct Input: Decodable, Sendable { let ids: [String]; let verdict: String? }
        static let name = "resolve-threat"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: update-threat-status unresolved or in_progress reopens each, and a verdict can be set again. Until then, resolving, or a false-positive verdict, hides it from the unresolved threats analysts and the alert watch look at, so resolve only what the champion judged handled or false."
        static let summary = "Resolve threats, optionally with an analyst verdict, false_positive included, which hides them from the unresolved queue. \(recovery)"
        static let input = JSONSchema.object([
            "ids": .array(.string("A threat's ID."), "The threats' IDs, as threats lists them, at most 50."),
            "verdict": .string("The analyst verdict to set with it.", oneOf: SentinelOne.verdicts),
        ], required: ["ids"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let verdict = try input.verdict.map { try ServiceInput.oneOf($0, SentinelOne.verdicts, "verdict") }
            return try await SentinelOne.setThreats(input.ids, status: "resolved", verdict: verdict, recovery: Self.recovery, on: service)
        }
    }

    struct UpdateThreatStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let ids: [String]; let status: String?; let verdict: String? }
        static let name = "update-threat-status"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Set threats in progress or unresolved, which reopens them, or set a verdict of true positive, suspicious or undefined. It hides nothing, so it is not held; resolve-threat resolves them or marks them false positives."
        static let input = JSONSchema.object([
            "ids": .array(.string("A threat's ID."), "The threats' IDs, as threats lists them, at most 50."),
            "status": .string("The incident status to set.", oneOf: ["unresolved", "in_progress"]),
            "verdict": .string("The analyst verdict to set.", oneOf: ["true_positive", "suspicious", "undefined"]),
        ], required: ["ids"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let status = try input.status.map { try ServiceInput.oneOf($0, ["unresolved", "in_progress"], "status") }
            let verdict = try input.verdict.map { try ServiceInput.oneOf($0, ["true_positive", "suspicious", "undefined"], "verdict") }
            return try await SentinelOne.setThreats(input.ids, status: status, verdict: verdict,
                                                    recovery: "Recovery: update-threat-status again sets another status or verdict; resolve-threat resolves them.", on: service)
        }
    }
}

// MARK: - Blocklist

extension SentinelOne {
    /// A hash as the blocklist takes it: a SHA1 or SHA256, lowercased.
    static func hash(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) else {
            throw ServiceError.input("Nothing was changed: give the file's SHA1 (40 hexadecimal characters) or SHA256 (64).")
        }
        return value
    }

    /// A blocklist entry as SentinelOne gives it; only its ID must be there.
    struct BlockEntry: Decodable, Sendable {
        let fields: [String: CellValue]
        let id: String
        init(from decoder: Decoder) throws {
            fields = try [String: CellValue](from: decoder)
            guard let raw = SentinelOne.text(fields, "id"), let id = SentinelOne.id(raw) else { throw ServiceError.unreadable }
            self.id = id
        }
        func text(_ key: String) -> String? { SentinelOne.text(fields, key) }
        var value: String? { text("value")?.lowercased() }
        var line: String {
            "\(text("type") ?? "?") \(value ?? "?") on \(text("osType") ?? "an OS not given"), scope \(text("scopeName") ?? text("scopePath") ?? "not given"), added by \(text("userName") ?? text("userId") ?? "someone not named") at \(text("createdAt") ?? "?")\(text("description").map { " — \(String($0.prefix(200)))" } ?? "") [\(id)]"
        }
    }

    /// Everything about an entry that says what it blocks and whether it changed, as SentinelOne gave it: what
    /// block-hash read back is kept, and unblock-hash removes an entry only while SentinelOne still gives exactly that.
    struct BlockSnapshot: Codable, Equatable, Sendable {
        var type: String?, value: String?, osType: String?, description: String?, site: String?, scope: String?, updated: String?, user: String?

        init(_ entry: BlockEntry) {
            func text(_ key: String) -> String? { entry.text(key) }
            type = text("type")?.lowercased(); value = entry.value; osType = text("osType")?.lowercased(); description = text("description")
            site = text("siteId"); scope = text("scopeName") ?? text("scopePath"); updated = text("updatedAt"); user = text("userId")
        }

        func differences(_ now: BlockSnapshot) -> [String] {
            var found: [String] = []
            func compare(_ name: String, _ was: String?, _ now: String?, required: Bool = false) {
                if required, was == nil || now == nil { found.append("\(name) \(was == nil ? "was" : "is") not given, so whether it changed cannot be told"); return }
                if was != now { found.append("\(name) \(was ?? "not given") is now \(now ?? "not given")") }
            }
            compare("type", type, now.type, required: true)
            compare("value", value, now.value, required: true)
            compare("OS", osType, now.osType, required: true)
            compare("site ID", site, now.site, required: true)
            compare("description", description, now.description)
            compare("scope", scope, now.scope)
            compare("updatedAt", updated, now.updated, required: true)
            compare("made by", user, now.user)
            return found
        }
    }

    /// A blocklist entry block-hash made: its ID, its site, when, and all SentinelOne gave of it.
    struct BlockRecord: Codable, Equatable, Sendable {
        let id: String
        let site: String
        let created: Date
        /// The entry as SentinelOne's answer to the request that made it gave it: what ownership rests on.
        let made: BlockSnapshot
        /// Whether reading it back first found it otherwise than made, so someone may have changed it since; then
        /// unblock-hash leaves it to the console.
        let changedSinceCreation: Bool
    }

    /// The entries block-hash made, the only ones unblock-hash removes, by connection and console: kept in memory, and in
    /// the file the app names, so they outlast a relaunch.
    struct BlockBook: Sendable {
        var file: URL? = nil
        var records: [String: [BlockRecord]] = [:]
    }
    static let blockBook = Mutex(BlockBook())

    /// Keeps Pion's record of the blocklist entries it made in `file`, reading what it already holds; nil keeps it in
    /// memory.
    public static func keepBlocklistRecords(at file: URL?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: [BlockRecord]].self, from: $0) } ?? [:]
        blockBook.withLock { $0 = BlockBook(file: file, records: saved) }
    }

    static func recordKey(_ service: ServiceClient) throws -> String {
        guard let account = service.account else {
            throw ServiceError.input("Nothing was changed: Pion cannot tell which connection this is, so it can keep no record of the blocklist entries it makes, and makes none.")
        }
        return "\(account.uuidString.lowercased())@\(try console(service))"
    }

    static func recorded(_ id: String, _ service: ServiceClient) throws -> BlockRecord? {
        let key = try recordKey(service)
        return blockBook.withLock { $0.records[key]?.first { $0.id == id } }
    }

    static func changeRecords(_ service: ServiceClient, _ change: (inout [BlockRecord]) -> Void) throws {
        let key = try recordKey(service)
        try blockBook.withLock { book in
            var records = book.records[key] ?? []
            change(&records)
            var changed = book.records
            changed[key] = records.isEmpty ? nil : records
            if let file = book.file {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(changed).write(to: file, options: .atomic)
            }
            book.records = changed
        }
    }

    /// Every blocklist entry for a hash that applies in a site, the site's own and those above it, read whole, or the
    /// read fails.
    static func blockEntries(_ hash: String, site: String, _ service: ServiceClient) async throws -> [BlockEntry] {
        let listing = try await read(blocklistNeed) {
            try await list(service, ["restrictions"], query: ["type": "black_hash", "value__contains": hash, "siteIds": site, "includeParents": "true"], as: BlockEntry.self,
                           size: 100, pages: 2, partial: false)
        }
        guard listing.complete else {
            throw ServiceError.input("Nothing was changed: not every blocklist entry for \(hash) could be read (\(listing.stopped ?? "more than Pion reads at once")), so whether one exists is not known.")
        }
        return listing.value.filter { $0.value == hash }
    }

    /// One blocklist entry by its exact ID, in the site it was made in.
    static func blockEntry(_ id: String, site: String, _ service: ServiceClient) async throws -> Lookup<BlockEntry> {
        try await read(blocklistNeed) {
            try await lookup(service, ["restrictions"], query: ["type": "black_hash", "ids": id, "siteIds": site], id: id, idOf: { (entry: BlockEntry) in entry.id }, what: "blocklist entry")
        }
    }

    /// One site by its exact ID, read whole, or a refusal.
    static func site(_ value: String, _ service: ServiceClient) async throws -> (id: String, name: String?) {
        guard let id = id(value) else { throw ServiceError.input("Nothing was changed: give the site's ID, digits only, as SentinelOne Detection's sites lists it.") }
        let listing = try await read(sitesNeed) { try await sites(service, query: ["siteIds": id], limit: 10, pages: 1) }
        let named = listing.value.filter { text($0, "id") == id }
        guard listing.complete, named.count == 1, listing.value.count == 1 else {
            throw ServiceError.input("Nothing was changed: SentinelOne did not return site \(id) alone (it gave \(plural(listing.value.count, "site"))), so where the entry would apply is not known. sites lists those in this token's scope.")
        }
        return (id, text(named[0], "name"))
    }

    struct BlockHash: ServiceOperation {
        struct Input: Decodable, Sendable { let hash: String; let osType: String; let siteId: String; let description: String }
        static let name = "block-hash"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: unblock-hash with the entry's ID removes it, which lets the file run again on the site's endpoints at once; a file the agents mitigated while it was blocked is not restored by that."
        static let summary = "Add a SHA1 or SHA256 to one site's blocklist for one OS, so the agents there stop the file running, and keep a record that Pion made it, which unblock-hash needs. Refused when any entry, in the site or above it, already holds the hash, whoever made it. \(recovery)"
        static let input = JSONSchema.object([
            "hash": .string("The file's SHA1 or SHA256."),
            "osType": .string("The OS it applies to.", oneOf: SentinelOne.osTypes),
            "siteId": .string("The one site it applies to, by ID, as SentinelOne Detection's sites lists it."),
            "description": .string("Why: the reason given in the approval request, with the Investigation."),
        ], required: ["hash", "osType", "siteId", "description"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let hash = try SentinelOne.hash(input.hash)
            let os = try ServiceInput.oneOf(input.osType, SentinelOne.osTypes, "osType")
            let words = input.description.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard (3...200).contains(words.count) else { throw ServiceError.input("Nothing was changed: give a description of up to 200 characters saying why, as the approval request does.") }
            let description = "Pion, after the champion's approval: " + words
            _ = try SentinelOne.recordKey(service)
            let site = try await SentinelOne.site(input.siteId, service)
            let existing = try await SentinelOne.blockEntries(hash, site: site.id, service)
            if let held = existing.first {
                let ours = (try? SentinelOne.recorded(held.id, service)) != nil
                throw ServiceError.input("Nothing was changed: a blocklist entry already holds \(hash), \(ours ? "which Pion made through this connection" : "which Pion has no record of making, so it leaves it alone"): \(held.line).")
            }
            let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "black_hash", "value": hash, "osType": os, "description": description],
                                                                   "filter": ["siteIds": [site.id]]], options: [.sortedKeys])
            let path = ["restrictions"]
            let answer = try await SentinelOne.read(SentinelOne.blockNeed) { try await SentinelOne.exchange(service, path, method: "POST", body: body) }
            let request = "Request: POST /web/api/v2.1/restrictions of black_hash \(hash) for \(os), in site \(site.id)."
            let noRecord = "Pion kept no record of it, so unblock-hash cannot remove it: read it with action-status, and remove it in the console if it was made and should go."
            // Ownership rests only on an answer that is plain: no error at all, and exactly one entry, of this type, hash
            // and OS, in this site.
            let given: [BlockEntry]?
            let problems: String?
            if let list = try? JSONDecoder().decode(Envelope<BlockEntry>.self, from: answer.data), list.data != nil {
                given = list.data; problems = list.problems
            } else if let one = try? JSONDecoder().decode(Single<BlockEntry>.self, from: answer.data) {
                given = one.data.map { [$0] }; problems = one.problems
            } else { given = nil; problems = nil }
            guard let given else {
                throw ServiceError.input("SentinelOne answered the request to block \(hash) with something that could not be read, so whether it made an entry is not known. \(noRecord)\n\(request)\n\(Self.recovery)")
            }
            if let problems {
                throw ServiceError.input("SentinelOne's answer to the request to block \(hash) carried errors (\(problems))\(given.isEmpty ? "" : " beside \(SentinelOne.plural(given.count, "entry"))"), so what it made is not plain and it is not reported done. \(noRecord)\n\(request)\n\(Self.recovery)")
            }
            guard given.count == 1, let made = given.first, made.value == hash, made.text("type")?.lowercased() == "black_hash", made.text("osType")?.lowercased() == os else {
                throw ServiceError.input("SentinelOne answered, but did not name exactly one black_hash entry for \(hash) on \(os) (it gave \(given.isEmpty ? "none" : given.prefix(3).map(\.line).joined(separator: "; "))), so whether it was made as asked could not be verified. \(noRecord)\n\(request)\n\(Self.recovery)")
            }
            guard SentinelOne.inSite(made, site.id) == true else {
                throw ServiceError.input("SentinelOne made blocklist entry \(made.id) for \(hash), but its answer \(SentinelOne.inSite(made, site.id) == false ? "places it in site \(made.text("siteId") ?? "?"), not \(site.id)" : "gives no site ID for it"), so where it applies could not be established. It is not reported done. \(noRecord)\n\(request)\n\(Self.recovery)")
            }
            let baseline = BlockSnapshot(made)
            // Read back in the site it was asked for, and compared with the answer that made it. One that differs is
            // recorded as changed since it was made, which unblock-hash leaves to the console.
            await SentinelOne.pause(SentinelOne.pauses.first ?? 0)
            let back: Lookup<BlockEntry>
            do { back = try await SentinelOne.blockEntry(made.id, site: site.id, service) } catch { back = .inconclusive(error.localizedDescription) }
            var unverified: String?, changed: [String] = []
            switch back {
            case .present(let entry):
                changed = baseline.differences(BlockSnapshot(entry))
                if SentinelOne.inSite(entry, site.id) != true, !changed.contains(where: { $0.hasPrefix("site ID") }) { changed.append("site ID is not \(site.id)") }
                if !changed.isEmpty { unverified = "read back in site \(site.id), it is not as SentinelOne said it made it: \(changed.joined(separator: "; "))" }
            case .absent: unverified = "read back in site \(site.id), SentinelOne holds no entry \(made.id)"
            case .inconclusive(let why): unverified = "reading it back in site \(site.id): \(why)"
            }
            do {
                try SentinelOne.changeRecords(service) { records in
                    records.removeAll { $0.id == made.id }
                    records.append(BlockRecord(id: made.id, site: site.id, created: Date(), made: baseline, changedSinceCreation: !changed.isEmpty))
                }
            } catch {
                throw ServiceError.input("SentinelOne made blocklist entry \(made.id) for \(hash), but Pion could not keep its record of it (\(error.localizedDescription)), so unblock-hash cannot remove it: remove it in the console when it should go.\n\(request)")
            }
            if let unverified {
                let kept = changed.isEmpty ? "Pion keeps its record of it as made, so unblock-hash with its ID can remove it while SentinelOne gives it as made."
                    : "Pion keeps its record, marked changed since it was made, so unblock-hash will not remove it: remove it in the console when it should go."
                throw ServiceError.input("SentinelOne answered that it made blocklist entry \(made.id) for \(hash) on \(os), but it could not be verified: \(unverified). It is not reported done. \(kept)\n\(request)\n\(Self.recovery)")
            }
            var lines = ["SentinelOne made blocklist entry \(made.id): \(hash) blocked on \(os) in site \(site.name ?? site.id) [\(site.id)], and read back there as made. Pion keeps a record that it made it, which unblock-hash needs.",
                         "The site's agents stop the file running once they take the change, within minutes; a process already running is not stopped by this."]
            if baseline.updated == nil { lines.append("SentinelOne gave no updatedAt for it, so unblock-hash cannot tell later whether it changed and will leave it in place; remove it in the console when it should go.") }
            lines.append(Self.recovery)
            struct Kept: Encodable { let id: String; let hash: String; let osType: String; let site: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(id: made.id, hash: hash, osType: os, site: site.id, done: true, recovery: Self.recovery))
        }
    }

    /// Whether an entry, as SentinelOne gives it, is in a site, by its site ID alone; nil when it gives none. A scope's
    /// name is only shown, never trusted, as two sites can share one.
    static func inSite(_ entry: BlockEntry, _ site: String) -> Bool? {
        entry.text("siteId").map { $0 == site }
    }

    struct UnblockHash: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "unblock-hash"
        static let jobs: Set<ToolJob> = [.containment]
        static let recovery = "Recovery: block-hash again restores it. Removing it lets the file run on every endpoint of the site at once."
        static let summary = "Remove one blocklist entry, by its ID, that Pion's own record says block-hash made through this connection and that SentinelOne still holds as made; any other is left in place, whatever its description says. Held, as it lifts a block. \(recovery)"
        static let input = JSONSchema.object(["id": .string("The entry's ID, as block-hash gave it.")], required: ["id"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = SentinelOne.id(input.id) else { throw ServiceError.input("Nothing was changed: give the entry's ID exactly as block-hash gave it.") }
            guard let record = try SentinelOne.recorded(id, service) else {
                throw ServiceError.input("Nothing was changed: Pion has no record of making blocklist entry \(id) through this connection, so it leaves it in place, whatever its description says. Remove it in the console if it should go.")
            }
            guard !record.changedSinceCreation else {
                throw ServiceError.input("Nothing was changed: blocklist entry \(id) was not as SentinelOne said it made it when Pion first read it back, so someone may have changed it, and Pion leaves it in place. Remove it in the console if it should go.")
            }
            let held: BlockEntry
            switch try await SentinelOne.blockEntry(id, site: record.site, service) {
            case .absent:
                try? SentinelOne.changeRecords(service) { $0.removeAll { $0.id == id } }
                throw ServiceError.input("Nothing was changed: SentinelOne says it holds no blocklist entry \(id) (\(record.made.value ?? "?")) in site \(record.site), so there is nothing to remove; Pion drops its record of it.")
            case .inconclusive(let why):
                throw ServiceError.input("Nothing was changed: whether SentinelOne still holds blocklist entry \(id) as Pion made it could not be told (\(why)), so it is left in place, and Pion keeps its record.")
            case .present(let entry): held = entry
            }
            var changed = record.made.differences(BlockSnapshot(held))
            if SentinelOne.inSite(held, record.site) != true, !changed.contains(where: { $0.hasPrefix("site ID") }) { changed.append("site ID \(held.text("siteId") ?? "not given") is not the approved \(record.site)") }
            guard changed.isEmpty else {
                throw ServiceError.input("Nothing was changed: blocklist entry \(id) is not, or cannot be shown to be, as Pion made it: \(changed.joined(separator: "; ")). Someone may have changed it, so Pion leaves it in place; remove it in the console if it should go.")
            }
            // By ID alone, of the one type: never a filter that could match more.
            let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "black_hash", "ids": [id]]], options: [.sortedKeys])
            let request = "Request: DELETE /web/api/v2.1/restrictions of black_hash entry \(id)."
            let answer = try await SentinelOne.read(SentinelOne.unblockNeed) { try await SentinelOne.exchange(service, ["restrictions"], method: "DELETE", body: body) }
            struct Affected: Decodable { let affected: Int? }
            // Removed only on an answer that counts exactly the one entry, with no error, and a read that then finds none.
            let said = try? JSONDecoder().decode(Single<Affected>.self, from: answer.data)
            if let problem = said == nil ? "SentinelOne's answer could not be read" : SentinelOne.countProblem(said?.data?.affected, expected: 1, problems: said?.problems) {
                throw ServiceError.input("SentinelOne took the request to remove blocklist entry \(id), but it could not be verified: \(problem). It is not reported removed, and Pion keeps its record; read it with action-status.\n\(request)\n\(Self.recovery)")
            }
            await SentinelOne.pause(SentinelOne.pauses.first ?? 0)
            let after: Lookup<BlockEntry>
            do { after = try await SentinelOne.blockEntry(id, site: record.site, service) } catch { after = .inconclusive("reading it again failed: \(error.localizedDescription)") }
            switch after {
            case .absent: break
            case .present(let still):
                throw ServiceError.input("SentinelOne still holds \(still.line) after the request to remove it, so it is not reported removed and Pion keeps its record.\n\(request)\n\(Self.recovery)")
            case .inconclusive(let why):
                throw ServiceError.input("SentinelOne took the request to remove blocklist entry \(id), but whether it is gone is unverified (\(why)), so it is not reported removed and Pion keeps its record. Read it with action-status.\n\(request)\n\(Self.recovery)")
            }
            var lines = ["Removed blocklist entry \(id), \(record.made.value ?? "?") on \(record.made.osType ?? "?") in site \(record.site), which Pion made through this connection: SentinelOne no longer holds it."]
            do { try SentinelOne.changeRecords(service) { $0.removeAll { $0.id == id } } }
            catch { lines.append("Pion could not drop its record of it (\(error.localizedDescription)); that changes nothing in SentinelOne.") }
            lines.append(Self.recovery)
            struct Kept: Encodable { let removed: String; let done: Bool; let recovery: String }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(removed: id, done: true, recovery: Self.recovery))
        }
    }
}

// MARK: - Following up, and access

extension SentinelOne {
    struct ActionStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let agentId: String?, threatId: String?, hash: String?, siteId: String? }
        static let name = "action-status"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Where an action stands: for an agent, its network and scan status; for a threat, its incident status, verdict and every mitigation action with where it stands (pending is not done); with either, the newest activity log entries about it; for a hash in a site, every blocklist entry that holds it and whether Pion's own record says block-hash made it through this connection. It changes nothing."
        static let input = JSONSchema.object([
            "agentId": SentinelOne.agentField,
            "threatId": SentinelOne.threatField,
            "hash": .string("A SHA1 or SHA256, with siteId."),
            "siteId": .string("The site whose blocklist to read, with hash."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var lines: [String] = []
            var activityQuery: [String: String?]?
            if let agent = input.agentId {
                let target = try await SentinelOne.targetAgent(agent, service)
                lines += [target.agent.line, "Disconnect from Network: \(SentinelOne.network(target.agent.network)); \(["disconnected", "connected"].contains(target.agent.network ?? "") ? "nothing about it is pending" : "not settled: poll again; it is done only once the status is disconnected or connected").",
                          "Scan: \(target.agent.scanStatus ?? "status not given")\(target.agent.text("scanStartedAt").map { ", started \($0)" } ?? "")\(target.agent.text("scanFinishedAt").map { ", finished \($0)" } ?? "")."]
                activityQuery = ["agentIds": target.agent.id]
            } else if let threat = input.threatId {
                let target = try await SentinelOne.targetThreat(threat, service)
                lines += [target.threat.line, "Mitigation actions: \(target.threat.mitigations.map { $0.isEmpty ? "none listed" : $0.map { "\($0.line) (\($0.outcome.rawValue))" }.joined(separator: "; ") } ?? "not given, so unknown")."]
                activityQuery = ["threatIds": target.threat.id]
            } else if let hash = input.hash, let site = input.siteId {
                let value = try SentinelOne.hash(hash)
                let siteID = try SentinelOne.requireID(site, "the site's ID")
                let entries = try await SentinelOne.blockEntries(value, site: siteID, service)
                let ours = entries.filter { (try? SentinelOne.recorded($0.id, service)) != nil }.map(\.id)
                lines.append(entries.isEmpty ? "No blocklist entry in site \(siteID), or above it, holds \(value)."
                             : entries.map { $0.line + (ours.contains($0.id) ? " — Pion's record says it made this one through this connection" : " — Pion has no record of making this one") }.joined(separator: "\n"))
            } else {
                throw ServiceError.input("Give an agent's ID, a threat's ID, or a hash with a site's ID.")
            }
            if var query = activityQuery {
                query["sortBy"] = "createdAt"; query["sortOrder"] = "desc"
                do {
                    let listing = try await SentinelOne.read(SentinelOne.activitiesNeed) {
                        try await SentinelOne.list(service, ["activities"], query: query, as: Activity.self, size: 10, pages: 1)
                    }
                    lines.append(listing.value.isEmpty ? "No activity log entry names it." : "Newest activity log entries about it:\n" + listing.value.map(\.line).joined(separator: "\n"))
                } catch { lines.append("The activity log could not be read: \(error.localizedDescription)") }
            }
            lines.append("Read at \(SentinelOne.iso(Date())).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["lines": lines])
        }
    }

    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Reads the token's own service user, its role, scope and when the token expires, warning of a built-in role broader than Containment needs; tries what the actions read first, agents, threats, the activity log, sites and the blocklist; and names the console it reaches. It sends only reads, so the actions' permissions are not verified."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let host = try SentinelOne.console(service)
            var lines = ["· Console \(host), reached at https://\(host)/web/api/v2.1 and nowhere else."]
            let (me, said) = await SentinelOne.whoAmI(service)
            lines += said
            if let me {
                let roles = me.roleNames
                let builtIn = roles.filter { ["admin", "site admin", "account admin", "global admin", "it", "soc", "ir team", "incident response"].contains($0) || $0.contains("admin") }
                if roles.isEmpty { lines.append("? Its role was not given, so whether it holds only Containment's permissions could not be told. Check it in Settings › Users › Service Users.") }
                else if roles.allSatisfy({ $0 == "viewer" }) { lines.append("✗ It holds only Viewer, which can take none of Containment's actions: give it the Pion Containment role.") }
                else if !builtIn.isEmpty { lines.append("⚠ It holds \(builtIn.joined(separator: ", ")), a built-in role that can do far more than Containment's actions, such as changing policies, exclusions or users: give it a custom role with only the permissions the Setup Steps list.") }
                else { lines.append("· It holds \(roles.joined(separator: ", ")): check in Settings › Users › Roles that it has only the permissions the Setup Steps list.") }
            }
            for (need, path, query) in [(SentinelOne.agentsNeed, ["agents"], [String: String?]()), (SentinelOne.threatsNeed, ["threats"], [:]), (SentinelOne.activitiesNeed, ["activities"], [:]),
                                        (SentinelOne.blocklistNeed, ["restrictions"], ["type": "black_hash"])] {
                lines.append(await SentinelOne.probe(need, path, query, required: true, service).line)
            }
            do {
                _ = try await SentinelOne.sites(service, query: [:], limit: 1, pages: 1)
                lines.append("✓ \(SentinelOne.sitesNeed.title) (\(SentinelOne.sitesNeed.permission))")
            } catch { lines.append("✗ \(SentinelOne.sitesNeed.title): " + (SentinelOne.fix(for: error, SentinelOne.sitesNeed) ?? error.localizedDescription)) }
            lines.append("· Not verified: \(SentinelOne.containmentPermissions.filter { !$0.hasSuffix(": View") }.joined(separator: ", ")). SentinelOne offers no way to list a role's actions without trying one, and check-access tries none; an action refused for want of one says which.")
            lines.append("· Pion Containment's service user should hold a custom role with only \(SentinelOne.containmentPermissions.joined(separator: ", ")): check it in Settings › Users › Roles.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
