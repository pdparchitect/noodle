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
