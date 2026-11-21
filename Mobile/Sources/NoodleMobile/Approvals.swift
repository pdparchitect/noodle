import HubLink
import SwiftUI

/// A call one of the person's bots holds for their approval, from whichever Hub runs it.
struct ApprovalEntry: Identifiable {
    let chats: HubChats
    let bot: LinkBot
    let approval: LinkApproval
    var id: UUID { approval.id }

    /// Every held call of the person's own bots, on every Hub, oldest first. Unlike tasks they are never filtered or
    /// left to one space: a held call waits until the person decides it.
    @MainActor static func listed(in hubs: [HubChats]) -> [ApprovalEntry] {
        hubs.flatMap { chats in
            chats.agents.filter { $0.owner == nil && $0.archivedAt == nil }.flatMap { bot in
                bot.approvals.map { ApprovalEntry(chats: chats, bot: bot, approval: $0) }
            }
        }.sorted { $0.approval.createdAt < $1.approval.createdAt }
    }

    /// The call in a few words, from the call itself: the tool and the first value it is given, such as who.
    var action: String {
        guard let first = approval.inputLines.first?.value, !first.isEmpty else { return approval.tool }
        return "\(approval.tool) \(first)"
    }

    @MainActor var thread: HubThread? { chats.threads.first { $0.conversationID == approval.conversationID } }
}

extension HubChats {
    /// The person's decision on a call one of their bots holds; the Hub runs an approved one, then the list follows.
    func decide(_ approval: LinkApproval, of bot: LinkBot, approve: Bool) async throws {
        _ = try await pairing.request(.decideApproval(LinkApprovalDecision(botID: bot.id, approvalID: approval.id, approve: approve)))
        try await reload()
    }
}

struct ApprovalListRow: View {
    let entry: ApprovalEntry

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(face: BotFace(entry.bot), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action)
                    .lineLimit(1)
                Text("\(entry.bot.draft.name) · \(entry.approval.providerTitle)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.approval.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

/// One held call in full: exactly what will run, from the call itself, and the bot's reason, marked as its own words.
struct ApprovalSheet: View {
    let entry: ApprovalEntry
    let openConversation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deciding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !entry.approval.toolDescription.isEmpty {
                        Text(entry.approval.toolDescription).foregroundStyle(.secondary)
                    }
                    ForEach(entry.approval.inputLines, id: \.name) { line in
                        LabeledContent(line.name) {
                            Text(line.value)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text(entry.approval.providerTitle)
                }
                Section {
                    Text(entry.approval.reason)
                } header: {
                    Text("\(entry.bot.draft.name) says")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Approve") { decide(true) }
                    Button("Decline", role: .destructive) { decide(false) }
                }
                .disabled(deciding)
                if entry.thread != nil {
                    Section {
                        Button("Open Conversation") {
                            dismiss()
                            openConversation()
                        }
                    }
                }
            }
            .navigationTitle(entry.approval.tool)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func decide(_ approve: Bool) {
        deciding = true
        Task {
            do {
                try await entry.chats.decide(entry.approval, of: entry.bot, approve: approve)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                deciding = false
            }
        }
    }
}
