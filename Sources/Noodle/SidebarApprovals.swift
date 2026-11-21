import AppKit
import NoodleCore
import SwiftUI

/// What the Approvals section needs from the app whose bots' tool calls are held for the person.
@MainActor protocol AgentApprovalHost: AnyObject {
    var approvals: AgentApprovalDesk { get }
    /// The bot's picture, 22 points across.
    func taskAvatar(_ agent: AgentRecord) -> AnyView
    func openConversation(for approval: AgentApproval, of agentID: UUID)
}

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
            AgentNotifications.withdrawApproval(approval.id)
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
        AgentNotifications.withdrawApproval(id)
        let decided = try await decide(approval, agent, approve)
        var list = byAgent[agentID] ?? load(agentID)
        if let index = list.firstIndex(where: { $0.id == decided.id }) { list[index] = decided }
        reload(list, of: agentID)
        onDecided(decided, agent)
        return decided
    }
}

/// The sidebar's Approvals section: every call a bot is waiting on the person to approve. It cannot be hidden or
/// collapsed, as a held call waits until someone decides it, and it shows only while one waits.
struct SidebarApprovals: View {
    let store: any AgentApprovalHost
    let agents: [AgentRecord]
    /// In a list, a section; in the icon grid, plain rows under a title.
    let inList: Bool

    var body: some View {
        let pending = store.approvals.pending(agents)
        if !pending.isEmpty {
            if inList {
                Section {
                    rows(pending)
                } header: {
                    Text("Approvals")
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approvals")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    rows(pending)
                }
            }
        }
    }

    private func rows(_ pending: [(agent: AgentRecord, approval: AgentApproval)]) -> some View {
        ForEach(pending, id: \.approval.id) { entry in
            ApprovalRow(store: store, agent: entry.agent, approval: entry.approval)
                .selectionDisabled()
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
        }
    }
}

private struct ApprovalRow: View {
    let store: any AgentApprovalHost
    let agent: AgentRecord
    let approval: AgentApproval
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 8) {
            store.taskAvatar(agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(ApprovalText.action(approval))
                    .lineLimit(1)
                Text("\(agent.displayName) · \(approval.providerTitle)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(SidebarTimestamp.text(for: approval.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isPresented = true }
        .help(approval.reason)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Approve") { store.approvals.decide(approval, of: agent, approve: true) }
            Button("Decline") { store.approvals.decide(approval, of: agent, approve: false) }
            Divider()
            Button("Open Conversation") { store.openConversation(for: approval, of: agent.id) }
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ApprovalPopover(store: store, agent: agent, approval: approval) { isPresented = false }
        }
    }
}

/// One held call in full: exactly what will run, from the call itself, and the bot's reason, marked as its own words.
private struct ApprovalPopover: View {
    let store: any AgentApprovalHost
    let agent: AgentRecord
    let approval: AgentApproval
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(approval.tool)
                    .font(.headline.monospaced())
                Spacer(minLength: 8)
                Text(approval.providerTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !approval.toolDescription.isEmpty {
                Text(approval.toolDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let lines = approval.inputLines
            if !lines.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(lines, id: \.name) { line in
                        GridRow {
                            Text(line.name)
                                .foregroundStyle(.secondary)
                            Text(line.value)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.displayName) says")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(approval.reason)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Conversation") {
                    store.openConversation(for: approval, of: agent.id)
                    dismiss()
                }
                .buttonStyle(.accentLink)
                Spacer()
                Button("Decline") {
                    store.approvals.decide(approval, of: agent, approve: false)
                    dismiss()
                }
                Button("Approve") {
                    store.approvals.decide(approval, of: agent, approve: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .disabled(store.approvals.deciding.contains(approval.id))
        }
        .padding(14)
        .frame(width: 340)
    }
}

enum ApprovalText {
    /// The call in a few words, from the call itself: the tool and the first value it is given, such as who.
    static func action(_ approval: AgentApproval) -> String {
        guard let first = approval.inputLines.first?.value, !first.isEmpty else { return approval.tool }
        return "\(approval.tool) \(first)"
    }
}
