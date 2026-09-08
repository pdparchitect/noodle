// Manual native UI fixture: no store, harness, persistence or message sending.
import SwiftUI
import NoodleCore

struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat
    var body: some View {
        Circle().fill(.blue.gradient).overlay(Text(String(agent.displayName.prefix(1))).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

private struct FixtureView: View {
    @StateObject private var completion = ComposerNameCompletion()
    @State private var draft = ""
    @State private var submissions = 0
    @State private var profile: AgentRecord?
    @State private var pendingReply: String?
    @State private var destination = "Group"
    @FocusState private var focused: Bool
    private let agents = [
        AgentRecord(displayName: "Angy", publicDescription: "Designs friendly interfaces."),
        AgentRecord(displayName: "Mara", publicDescription: "Reviews ideas and asks useful questions."),
        AgentRecord(displayName: "Mary Jane"),
        AgentRecord(displayName: "Ruby"),
        AgentRecord(displayName: "Tony"),
        AgentRecord(displayName: "Zoe")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(destination) — submissions: \(submissions)").font(.headline)
            Button("Show Mara's profile") { profile = agents[1] }
            Spacer()
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                .background(ChatComposerBridge(isActive: focused, draft: draft, agents: agents,
                                               preferredIDs: [agents[1].id], completion: completion))
                .onSubmit { submissions += 1 }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    if focused && !completion.candidates.isEmpty {
                        AgentNameSuggestions(completion: completion).offset(y: -completion.popupHeight - 8)
                    }
                }
        }
        .padding(24).frame(width: 540, height: 450)
        .sheet(item: $profile, onDismiss: {
            if let pendingReply { draft = pendingReply + ", " + draft; self.pendingReply = nil }
            DispatchQueue.main.async { focused = true }
        }) { agent in
            AgentProfileSheet(agent: agent, canOpenDirectMessage: true, reply: {
                pendingReply = agent.displayName
                profile = nil
            }, directMessage: {
                destination = "Direct: \(agent.displayName)"
                profile = nil
            }).noodleSheetSizing()
        }
        .onDisappear { completion.detach() }
    }
}

@main
struct ChatFeaturesTest: App {
    var body: some Scene {
        WindowGroup("Chat Feature Tests") { FixtureView().preferredColorScheme(.dark) }
    }
}
