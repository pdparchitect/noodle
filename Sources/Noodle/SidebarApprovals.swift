import AppKit
import HubLink
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
                // The tool, then what it is given, dimmed, so a script never reads as the call's name.
                Text("\(approval.tool)\(Text(ApprovalText.argument(approval).map { " \($0)" } ?? "").foregroundStyle(.secondary))")
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
struct ApprovalPopover: View {
    let store: any AgentApprovalHost
    let agent: AgentRecord
    let approval: AgentApproval
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(approval.tool)
                    .font(.body.monospaced().weight(.semibold))
                Spacer(minLength: 8)
                Text(approval.providerTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // A server's tool can come with a whole manual and take a whole script, so the call scrolls and the
            // buttons stay on screen.
            CappedHeight(limit: 360) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !approval.toolDescription.isEmpty {
                            Text(approval.toolDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let lines = approval.inputLines
                        if !lines.isEmpty {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                                ForEach(lines, id: \.name) { line in
                                    GridRow {
                                        // Written as a key in the call, so it reads as the value's name.
                                        Text("\(line.name):")
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.secondary)
                                        ApprovalValue(value: line.value)
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(agent.displayName) says")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(approval.reason)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
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

/// Its one view as tall as it would be, up to `limit`.
private struct CappedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// One value of a held call. One of several lines, such as a script, shows its first few until clicked, and its
/// lines are never wrapped, as wrapping hyphenates them and they would no longer read as what will run.
private struct ApprovalValue: View {
    let value: String
    @State private var isExpanded = false
    private static let collapsedLines = 3
    private static var codeAscender: CGFloat {
        NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular).ascender
    }

    var body: some View {
        let lines = value.components(separatedBy: "\n")
        if lines.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal) {
                    Text(isExpanded ? value : lines.prefix(Self.collapsedLines).joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize()
                }
                .scrollBounceBehavior(.basedOnSize)
                // A scroll view has no baseline, so the value's name would line up with the button below instead.
                .alignmentGuide(.firstTextBaseline) { $0[.top] + Self.codeAscender }
                if lines.count > Self.collapsedLines {
                    Button(isExpanded ? "Show Less" : "Show All \(lines.count) Lines") { isExpanded.toggle() }
                        .buttonStyle(.accentLink)
                        .font(.callout)
                }
            }
        } else {
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ApprovalText {
    /// The first value the call is given, such as who, on one line: what the row shows after the tool.
    static func argument(_ approval: AgentApproval) -> String? {
        guard let first = approval.inputLines.first?.value.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
        return first
    }
}
