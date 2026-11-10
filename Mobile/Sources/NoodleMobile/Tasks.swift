import HubLink
import SwiftUI

/// One of a bot's open tasks in the conversation list, with the conversation to write about it in.
struct TaskEntry: Identifiable {
    let chats: HubChats
    let bot: LinkBot
    let task: LinkTask
    let thread: HubThread
    var id: UUID { task.id }

    /// The open tasks of the owner's bots whose conversations are among `threads`, as the Mac lists them:
    /// those waiting on the person first, then the ones in progress, then those waiting on someone else,
    /// the most recently changed first within each.
    @MainActor static func listed(in threads: [(chats: HubChats, thread: HubThread)], filter: TaskListFilter) -> [TaskEntry] {
        guard filter != .hidden else { return [] }
        func rank(_ task: LinkTask) -> Int { task.waitingOn == .you ? 0 : task.state == .open ? 1 : 2 }
        var seen = Set<ObjectIdentifier>()
        let hubs = threads.map(\.chats).filter { seen.insert(ObjectIdentifier($0)).inserted }
        return hubs.flatMap { chats in
            chats.agents.filter { $0.owner == nil && $0.archivedAt == nil }.flatMap { bot in
                bot.tasks.compactMap { task -> TaskEntry? in
                    guard filter == .allOpen || task.waitingOn == .you,
                          let thread = threads.first(where: { $0.chats === chats && $0.thread.conversationID == task.conversationID })?.thread
                    else { return nil }
                    return TaskEntry(chats: chats, bot: bot, task: task, thread: thread)
                }
            }
        }.sorted { (rank($0.task), $1.task.updatedAt) < (rank($1.task), $0.task.updatedAt) }
    }

    @MainActor var stateLine: String {
        switch task.waitingOn {
        case .you: "Waiting on you"
        case .bot(let id): "Waiting on \(chats.agents.first { $0.id == id }?.draft.name ?? "a bot")"
        case nil: task.state == .waiting ? "Waiting" : "In progress"
        }
    }

    var symbol: String { task.state == .waiting ? "circle.lefthalf.filled" : "circle.fill" }
}

struct TaskListRow: View {
    let entry: TaskEntry

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(face: BotFace(entry.bot), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.task.title)
                    .lineLimit(1)
                Text("\(entry.bot.draft.name) · \(entry.stateLine)")
                    .font(.caption)
                    .foregroundStyle(entry.task.waitingOn == .you ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.task.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

/// Writing to a bot about one of its tasks. The words go to the task's conversation, carrying the
/// task, and the bot moves the task on; nothing here changes it.
struct TaskFeedbackSheet: View {
    let entry: TaskEntry
    let openConversation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(entry.stateLine, systemImage: entry.symbol)
                        .foregroundStyle(entry.task.waitingOn == .you ? Color.accentColor : .secondary)
                    if let note = entry.task.note { Text(note).foregroundStyle(.secondary) }
                } header: {
                    Text(entry.bot.draft.name)
                }
                Section {
                    TextField("Message \(entry.bot.draft.name)", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Open Conversation") {
                        dismiss()
                        openConversation()
                    }
                }
            }
            .navigationTitle(entry.task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        Task {
            do {
                try await entry.chats.send(body, to: entry.thread, task: LinkTaskReference(id: entry.task.id, botID: entry.bot.id,
                                                                                         title: entry.task.title))
                dismiss()
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }
}
