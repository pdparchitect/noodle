#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WindowsPOSIX
#endif
import Foundation
import ProductIdentity

/// A tool call held for the person's decision. Only calls a connection's server marks destructive are held, such as
/// suspending a user; anything else runs on the bot's call, so ordinary changes never ask. Unlike a task, the bot never
/// changes one: what will run is fixed when it is held, and only the person's decision moves it on.
public struct AgentApproval: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case pending, running, done, failed, declined, expired

        public var isFinished: Bool { self != .pending && self != .running }
    }

    /// What a held tool takes besides its own input: why, in the bot's words, and the conversation it belongs to.
    public static let reasonParameter = "approval-reason"
    public static let conversationParameter = "approval-conversation"
    /// The `_meta` key of the host's answer to a held call, `{ id, state }`, which no server can send: whatever carries
    /// it never reached the service.
    public static let heldMarker = "noodle/approval"

    public let id: UUID
    /// Where the bot asked; its direct conversation with the person when it named none.
    public let conversationID: UUID?
    /// The tool provider, as bots name it, and its title, such as the connection's name.
    public let provider: String
    public let providerTitle: String
    public let tool: String
    /// The tool's own description, from its server.
    public let toolDescription: String
    /// The call's input exactly as it will be sent, as JSON with sorted keys.
    public let input: String
    /// Where in its workspace the bot made the call, so file arguments resolve as they would have.
    public let currentDirectory: String
    /// The bot's own words, never what decides the call.
    public let reason: String
    public var state: State
    /// What the service answered, or why it could not run.
    public var result: String?
    /// Who approved or declined it.
    public var decidedBy: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), conversationID: UUID?, provider: String, providerTitle: String, tool: String, toolDescription: String = "",
                input: String, currentDirectory: String = "", reason: String, state: State = .pending, result: String? = nil,
                decidedBy: String? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id; self.conversationID = conversationID; self.provider = provider; self.providerTitle = providerTitle
        self.tool = tool; self.toolDescription = toolDescription; self.input = input; self.currentDirectory = currentDirectory
        self.reason = reason; self.state = state; self.result = result; self.decidedBy = decidedBy
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    /// Whether a tool, by its MCP annotations, is held: only one its server marks destructive, and never one it also
    /// marks read-only. A server that does not label its tools is never held, though MCP says to assume the worst, so
    /// ordinary changes such as filing an issue do not ask.
    // TODO: Let a person override this per connection, such as holding every change of a server that labels nothing,
    // or never holding one they trust.
    public static func asks(annotations: [String: Any]?) -> Bool {
        annotations?["destructiveHint"] as? Bool == true && annotations?["readOnlyHint"] as? Bool != true
    }

    /// The input as one line per value, for the person to read before deciding.
    public var inputLines: [(name: String, value: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            let value = object[key]
            if let text = value as? String { return (key, text) }
            let data = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) }
            return (key, data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
    }

    /// The wake note the bot gets once the person decided, as `<tool-alerts>` notes are given.
    public var outcomeNote: String {
        let said: String
        switch state {
        case .done: said = "was approved and ran"
        case .failed: said = "was approved, but did not succeed"
        case .declined: said = "was declined"
        case .expired: said = "expired without an answer"
        case .pending, .running: said = "is waiting"
        }
        var note = "<approval id=\"\(id.uuidString)\">Your held call to \(tool) on \(providerTitle) \(said)"
        if let decidedBy, state != .expired { note += " by \(decidedBy)" }
        note += "."
        if let result, !result.isEmpty { note += " The service said: \(result)" }
        return note + " --list-approvals shows it.</approval>"
    }
}

public enum AgentApprovalLimits {
    /// Held calls one bot can have waiting, so a runaway bot cannot flood the person.
    public static let pending = 20
    public static let reasonLength = 500
    public static let resultLength = 2_000
    /// How long a held call waits for the person before it expires.
    public static let pendingKept: TimeInterval = 86_400
    /// A run that never recorded its end, such as when the app quit mid-call.
    public static let runningKept: TimeInterval = 600
    /// How long a decided one stays listed.
    public static let finishedKept: TimeInterval = 7 * 86_400
}

public struct AgentApprovalError: LocalizedError, Equatable {
    public let errorDescription: String?
    public init(_ description: String) { errorDescription = description }
}

/// What the broker asks the app to hold.
public struct AgentApprovalRequest: Sendable {
    public let agentID: UUID
    public let conversationID: UUID?
    public let provider: String
    public let providerTitle: String
    public let tool: String
    public let toolDescription: String
    public let input: String
    public let currentDirectory: String
    public let reason: String

    public init(agentID: UUID, conversationID: UUID?, provider: String, providerTitle: String, tool: String, toolDescription: String = "",
                input: String, currentDirectory: String = "", reason: String) {
        self.agentID = agentID; self.conversationID = conversationID; self.provider = provider; self.providerTitle = providerTitle
        self.tool = tool; self.toolDescription = toolDescription; self.input = input; self.currentDirectory = currentDirectory
        self.reason = reason
    }
}

extension WorkspaceRepository {
    /// Holds a call for the person. Without a conversation it belongs to the bot's direct one.
    public func addApproval(_ request: AgentApprovalRequest, now: Date = Date()) throws -> AgentApproval {
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw AgentApprovalError("\(request.tool) changes something the person must approve first. Say why in --\(AgentApproval.reasonParameter): what you found, and what this call will do about it.")
        }
        guard reason.count <= AgentApprovalLimits.reasonLength else {
            throw AgentApprovalError("--\(AgentApproval.reasonParameter) is at most \(AgentApprovalLimits.reasonLength) characters.")
        }
        let conversations = try loadConversations()
        let conversation: UUID?
        if let id = request.conversationID {
            _ = try participantRoster(for: request.agentID, conversationID: id)
            conversation = id
        } else {
            conversation = conversations.first { $0.kind == .direct && $0.participantIDs == [request.agentID] }?.id
        }
        return try updateApprovals(agentID: request.agentID, now: now) { approvals in
            guard approvals.filter({ $0.state == .pending }).count < AgentApprovalLimits.pending else {
                throw AgentApprovalError("You already have \(AgentApprovalLimits.pending) calls waiting for approval. Wait for the person to decide them.")
            }
            let approval = AgentApproval(conversationID: conversation, provider: request.provider, providerTitle: request.providerTitle,
                                         tool: request.tool, toolDescription: request.toolDescription, input: request.input,
                                         currentDirectory: request.currentDirectory, reason: reason, createdAt: Self.approvalSeconds(now))
            approvals.append(approval)
            return approval
        }
    }

    /// The bot's held calls, oldest first, once unanswered ones expired and decided ones past their week are cleared.
    public func currentApprovals(agentID: UUID, now: Date = Date()) throws -> [AgentApproval] {
        try updateApprovals(agentID: agentID, now: now) { $0 }
    }

    /// The person's decision on a pending call: an approved one is marked running, so it runs once.
    public func claimApproval(agentID: UUID, id: UUID, approve: Bool, by person: String, now: Date = Date()) throws -> AgentApproval {
        try updateApprovals(agentID: agentID, now: now) { approvals in
            guard let index = approvals.firstIndex(where: { $0.id == id }) else { throw AgentApprovalError("This approval is no longer listed.") }
            guard approvals[index].state == .pending else {
                throw AgentApprovalError(approvals[index].state == .expired ? "This approval expired." : "This approval was already decided.")
            }
            approvals[index].state = approve ? .running : .declined
            approvals[index].decidedBy = person
            approvals[index].updatedAt = Self.approvalSeconds(now)
            return approvals[index]
        }
    }

    /// Records how an approved call ended.
    public func finishApproval(agentID: UUID, id: UUID, succeeded: Bool, result: String, now: Date = Date()) throws -> AgentApproval {
        try updateApprovals(agentID: agentID, now: now) { approvals in
            guard let index = approvals.firstIndex(where: { $0.id == id }) else { throw AgentApprovalError("This approval is no longer listed.") }
            approvals[index].state = succeeded ? .done : .failed
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            approvals[index].result = text.isEmpty ? nil : String(text.prefix(AgentApprovalLimits.resultLength))
            approvals[index].updatedAt = Self.approvalSeconds(now)
            return approvals[index]
        }
    }

    /// Puts a copy of a bot's held calls in place, as a Hub lists them for a bot it runs. Returns whether they changed.
    @discardableResult
    public func replaceApprovals(agentID: UUID, with approvals: [AgentApproval], now: Date = Date()) throws -> Bool {
        try updateApprovals(agentID: agentID, now: now) { current in
            defer { current = approvals }
            return current != approvals
        }
    }

    /// The bot's held calls as stored, without expiring or clearing anything.
    public func loadApprovals(agentID: UUID) throws -> [AgentApproval] {
        let url = approvalsURL(agentID: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentApproval].self, from: Data(contentsOf: url))
    }

    private static func approvalSeconds(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    private func approvalsURL(agentID: UUID) -> URL { storage(for: agentID).package.appendingPathComponent("approvals.json") }

    /// As tasks are: the broker, Messenger and the app change the file from different threads, so changes take a lock.
    /// Every change also expires what waited too long and clears what was decided past its week or whose thread is gone.
    private func updateApprovals<Value>(agentID: UUID, now: Date, _ change: (inout [AgentApproval]) throws -> Value) throws -> Value {
        let package = storage(for: agentID).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agentID) }
        let threads = Set(try loadConversations().map(\.id))
        let descriptor = systemOpen(package.appendingPathComponent(".approvals.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { systemClose(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let original = try loadApprovals(agentID: agentID)
        let stamp = Self.approvalSeconds(now)
        var approvals = original.compactMap { approval -> AgentApproval? in
            guard approval.conversationID.map(threads.contains) ?? true,
                  !(approval.state.isFinished && now.timeIntervalSince(approval.updatedAt) > AgentApprovalLimits.finishedKept) else { return nil }
            var approval = approval
            if approval.state == .pending, now.timeIntervalSince(approval.createdAt) > AgentApprovalLimits.pendingKept {
                approval.state = .expired; approval.updatedAt = stamp
            } else if approval.state == .running, now.timeIntervalSince(approval.updatedAt) > AgentApprovalLimits.runningKept {
                approval.state = .failed; approval.updatedAt = stamp
                approval.result = "It was approved, but whether it ran is unknown. Check before asking again."
            }
            return approval
        }
        let value = try change(&approvals)
        if approvals != original {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(approvals), to: approvalsURL(agentID: agentID))
        }
        return value
    }
}

extension AgentApproval {
    /// Pending ones across bots, oldest first, as every app lists them: the person decides in the order they were asked.
    /// Archived bots' are left out.
    public static func pendingList(_ approvals: [(agent: AgentRecord, approvals: [AgentApproval])]) -> [(agent: AgentRecord, approval: AgentApproval)] {
        approvals.filter { $0.agent.archivedAt == nil }
            .flatMap { entry in entry.approvals.filter { $0.state == .pending }.map { (agent: entry.agent, approval: $0) } }
            .sorted { $0.approval.createdAt < $1.approval.createdAt }
    }
}

extension ToolBroker {
    /// Holds a call the broker found destructive: nothing reaches the service, and the bot gets the approval's ID at once.
    static func hold(_ descriptor: ToolDescriptor, provider: ToolProviderManifest, arguments: Data, conversation: UUID?,
                     currentDirectory: String, agent: UUID, host: ToolHostServices) throws -> Data {
        guard let hold = host.hold else {
            throw ToolProviderError("\(descriptor.name) needs the person's approval, which \(ProductIdentity.current.name) cannot ask for here, so it was not run.")
        }
        guard var object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ToolProviderError("Tool arguments must be a JSON object.")
        }
        let reason = object.removeValue(forKey: AgentApproval.reasonParameter) as? String ?? ""
        object.removeValue(forKey: AgentApproval.conversationParameter)
        let input = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let approval: AgentApproval
        do {
            approval = try hold(AgentApprovalRequest(agentID: agent, conversationID: conversation, provider: provider.id, providerTitle: provider.title,
                                                    tool: descriptor.name, toolDescription: descriptor.description, input: input,
                                                    currentDirectory: currentDirectory, reason: reason))
        } catch let error as AgentApprovalError { throw ToolProviderError(error.errorDescription ?? "") }
        let text = """
            Held for the person's approval as \(approval.id.uuidString); nothing has run yet. You are woken with the outcome, \
            and --list-approvals shows it meanwhile. Do not call it again while it waits.
            """
        return try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": text]], "isError": false,
            "_meta": [AgentApproval.heldMarker: ["id": approval.id.uuidString, "state": approval.state.rawValue]],
        ], options: [.sortedKeys])
    }

    /// The person's decision on a held call. An approved one runs once through the broker, as the bot's own call would,
    /// with the bot's assignments as they are now; the outcome is recorded and returned.
    public static func decide(approval id: UUID, of agent: UUID, approve: Bool, by person: String, repository: WorkspaceRepository,
                              registry: ToolProviderRegistry, assignments: @escaping @Sendable () -> ToolAssignments,
                              workspace: URL, host: ToolHostServices) async throws -> AgentApproval {
        let claimed = try repository.claimApproval(agentID: agent, id: id, approve: approve, by: person)
        guard approve else { return claimed }
        let request = ToolBridgeRequest(session: "", action: .call, provider: claimed.provider, tool: claimed.tool,
                                        arguments: Data(claimed.input.utf8), currentDirectory: claimed.currentDirectory)
        do {
            let data = try await perform(request, registry: registry, assignments: assignments,
                                         context: ToolCallContext(agentID: agent, workspace: workspace), host: host, approved: true)
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let text = ((object["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return try repository.finishApproval(agentID: agent, id: id, succeeded: object["isError"] as? Bool != true, result: text)
        } catch {
            return try repository.finishApproval(agentID: agent, id: id, succeeded: false, result: error.localizedDescription)
        }
    }
}
