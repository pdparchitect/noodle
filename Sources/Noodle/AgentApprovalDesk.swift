import Foundation
import NoodleCore
import Observation

/// The bots' held calls, as the sidebar and notifications show them, and the person's decisions on them. The app
/// says how a decision is carried out: on this Mac through its tool broker, or by the Hub that holds the call.
@MainActor @Observable final class AgentApprovalDesk {
    private(set) var byAgent: [UUID: [AgentApproval]] = [:]
    /// Those being decided, so a second click cannot decide one again.
    private(set) var deciding: Set<UUID> = []
    /// Pending ones the person has been told of, so a reload does not tell them again.
    @ObservationIgnored private var announced: Set<UUID> = []
    @ObservationIgnored private var loaded = false

    /// Carries out a decision and returns the approval as it ended.
    @ObservationIgnored var decide: (AgentApproval, AgentRecord, Bool) async throws -> AgentApproval = { approval, _, _ in approval }
    /// Removes the system notification for a call that is being settled or was decided elsewhere.
    @ObservationIgnored var withdrawNotification: (UUID) -> Void = { _ in }
    /// A newly held call, for a notification.
    @ObservationIgnored var onPending: (AgentApproval, AgentRecord) -> Void = { _, _ in }
    /// A decided one, so its bot hears the outcome.
    @ObservationIgnored var onDecided: (AgentApproval, AgentRecord) -> Void = { _, _ in }
    /// How many wait changed, for the Dock badge.
    @ObservationIgnored var onCountChanged: () -> Void = {}
    /// A bot's changed, so the owner's devices this Mac serves list them again.
    @ObservationIgnored var onAgentChanged: (UUID) -> Void = { _ in }
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    @ObservationIgnored var agent: (UUID) -> AgentRecord? = { _ in nil }
    /// A bot's held calls as kept now.
    @ObservationIgnored var load: (UUID) -> [AgentApproval] = { _ in [] }

    /// A bot held a call, or one of its calls changed elsewhere.
    func reload(agent id: UUID) { reload(load(id), of: id) }

    /// Every bot's, as when the app starts. Those already waiting were announced when they were held.
    func reload(_ approvals: [UUID: [AgentApproval]]) {
        let first = !loaded
        loaded = true
        for (id, list) in approvals { apply(list, of: id, announce: !first) }
        for id in byAgent.keys where approvals[id] == nil { byAgent[id] = nil }
        onCountChanged()
    }

    /// One bot's, as when it held a call or a Hub listed them.
    func reload(_ approvals: [AgentApproval], of agentID: UUID) {
        apply(approvals, of: agentID, announce: loaded)
        onCountChanged()
        onAgentChanged(agentID)
    }

    private func apply(_ approvals: [AgentApproval], of agentID: UUID, announce: Bool) {
        if byAgent[agentID] != approvals { byAgent[agentID] = approvals.isEmpty ? nil : approvals }
        for approval in approvals where approval.state == .pending && announced.insert(approval.id).inserted && announce {
            if let agent = agent(agentID) { onPending(approval, agent) }
        }
        let pending = Set(approvals.filter { $0.state == .pending }.map(\.id))
        for approval in approvals where !pending.contains(approval.id) && announced.remove(approval.id) != nil {
            withdrawNotification(approval.id)
        }
    }

    /// Waiting ones, oldest first, of the bots `agents` lists.
    func pending(_ agents: [AgentRecord]) -> [(agent: AgentRecord, approval: AgentApproval)] {
        AgentApproval.pendingList(agents.compactMap { agent in byAgent[agent.id].map { (agent: agent, approvals: $0) } })
    }

    var pendingCount: Int { byAgent.values.reduce(0) { $0 + $1.filter { $0.state == .pending }.count } }

    /// A decision from a notification's button.
    func decide(_ id: UUID, of agentID: UUID, approve: Bool) {
        Task {
            do { try await settle(id, of: agentID, approve: approve) } catch { onError(error.localizedDescription) }
        }
    }

    func decide(_ approval: AgentApproval, of agent: AgentRecord, approve: Bool) {
        decide(approval.id, of: agent.id, approve: approve)
    }

    /// Carries out a decision, from this Mac or from a device it serves, and returns how the call ended.
    @discardableResult
    func settle(_ id: UUID, of agentID: UUID, approve: Bool) async throws -> AgentApproval {
        guard let agent = agent(agentID) else { throw AgentApprovalError("There is no such bot.") }
        guard let approval = (byAgent[agentID] ?? load(agentID)).first(where: { $0.id == id }), approval.state == .pending else {
            throw AgentApprovalError("This approval was already decided.")
        }
        guard deciding.insert(id).inserted else { throw AgentApprovalError("This approval is being decided.") }
        defer { deciding.remove(id) }
        withdrawNotification(id)
        let decided = try await decide(approval, agent, approve)
        var list = byAgent[agentID] ?? load(agentID)
        if let index = list.firstIndex(where: { $0.id == decided.id }) { list[index] = decided }
        reload(list, of: agentID)
        onDecided(decided, agent)
        return decided
    }
}
