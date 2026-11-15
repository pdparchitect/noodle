import SwiftUI
import HubLink
import NoodleCore

/// What the Tasks section needs from the app whose bots keep tasks.
@MainActor protocol AgentTaskHost: AnyObject {
    func openTasks(waitingOnMeOnly: Bool) -> [(agent: AgentRecord, task: AgentTask)]
    func taskAgentName(_ id: UUID) -> String?
    /// The bot's picture, 22 points across.
    func taskAvatar(_ agent: AgentRecord) -> AnyView
    func openConversation(for task: AgentTask, of agentID: UUID)
    func sendFeedback(_ text: String, on task: AgentTask, of agentID: UUID) throws
    func reportTaskError(_ message: String)
}

/// The sidebar's Tasks section: a few tasks, then a link to the rest. Clicking a task opens a
/// popover for writing to its bot about it, never a control that changes the task.
struct SidebarTasks: View {
    let store: any AgentTaskHost
    let filter: TaskListFilter
    /// In a list, a collapsible section; in the icon grid, plain rows under a title.
    let inList: Bool
    @State private var isExpanded = true
    @State private var showsAll = false

    private static let collapsedCount = 5

    var body: some View {
        let tasks = store.openTasks(waitingOnMeOnly: filter == .waitingOnMe)
        if filter != .hidden, !tasks.isEmpty {
            let shown = showsAll ? tasks : Array(tasks.prefix(Self.collapsedCount))
            if inList {
                Section(isExpanded: $isExpanded) {
                    rows(shown, total: tasks.count)
                } header: {
                    Text("Tasks")
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tasks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    rows(shown, total: tasks.count)
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ shown: [(agent: AgentRecord, task: AgentTask)], total: Int) -> some View {
        ForEach(shown, id: \.task.id) { entry in
            TaskRow(store: store, agent: entry.agent, task: entry.task)
                .selectionDisabled()
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
        }
        if total > Self.collapsedCount {
            Button(showsAll ? "Show Fewer" : "Show All \(total)") { showsAll.toggle() }
                .buttonStyle(.link)
                .selectionDisabled()
        }
    }
}

private struct TaskRow: View {
    let store: any AgentTaskHost
    let agent: AgentRecord
    let task: AgentTask
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 8) {
            store.taskAvatar(agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .lineLimit(1)
                Text("\(agent.displayName) · \(TaskState.line(for: task, store: store))")
                    .font(.caption)
                    .foregroundStyle(task.waitingOn == .user ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(SidebarTimestamp.text(for: task.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isPresented = true }
        .help(task.note ?? task.title)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            TaskFeedbackPopover(store: store, agent: agent, task: task) { isPresented = false }
        }
    }
}

/// Writing to a bot about one of its tasks. The words go to the task's conversation, carrying the
/// task, and the bot moves the task on.
private struct TaskFeedbackPopover: View {
    let store: any AgentTaskHost
    let agent: AgentRecord
    let task: AgentTask
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(agent.displayName)
                    .foregroundStyle(.secondary)
            }
            Label(TaskState.line(for: task, store: store), systemImage: TaskState.symbol(for: task))
                .foregroundStyle(task.waitingOn == .user ? Color.accentColor : .secondary)
            if let note = task.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Message \(agent.displayName)", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            HStack {
                Button("Open Conversation") {
                    store.openConversation(for: task, of: agent.id)
                    dismiss()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Send") {
                    do {
                        try store.sendFeedback(text, on: task, of: agent.id)
                        dismiss()
                    } catch {
                        store.reportTaskError(error.localizedDescription)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}

@MainActor
enum TaskState {
    static func line(for task: AgentTask, store: any AgentTaskHost) -> String {
        switch task.state {
        case .open: return "In progress"
        case .done: return "Done"
        case .dropped: return "Dropped"
        case .waiting:
            switch task.waitingOn {
            case .user: return "Waiting on you"
            case .agent(let id): return "Waiting on \(store.taskAgentName(id) ?? "a bot")"
            case .system, nil: return "Waiting"
            }
        }
    }

    static func symbol(for task: AgentTask) -> String {
        switch task.state {
        case .open: "circle.fill"
        case .waiting: "circle.lefthalf.filled"
        case .done: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }
}

/// Time for today, day and month for this year, and the year only when it differs.
enum SidebarTimestamp {
    static func text(
        for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        style = style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
