// Manual native UI fixture: no store, harness, persistence or message sending.
import AppKit
import SwiftUI
import NoodleCore

private func fixtureAvatarData() -> Data? {
    NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        rect.fill()
        return true
    }.tiffRepresentation
}

@MainActor private func verifyNativeMenuPresentation() {
    let agent = AgentRecord(displayName: "Mara", publicDescription: "  Reviews\n ideas.  ", avatarImageData: fixtureAvatarData())
    precondition(ComposerNameCompletion.menuTitle(for: agent, showDescriptions: false) == "Mara")
    precondition(ComposerNameCompletion.menuTitle(for: agent, showDescriptions: true) == "Mara  Reviews ideas.")
    precondition(ComposerNameCompletion.menuTitle(for: AgentRecord(displayName: "Ruby"), showDescriptions: true) == "Ruby")
    let long = AgentRecord(displayName: "Long", publicDescription: String(repeating: "x", count: 200))
    precondition(ComposerNameCompletion.menuTitle(for: long, showDescriptions: true) == "Long  " + String(repeating: "x", count: 72) + "…")
    let avatar = ComposerNameCompletion.menuAvatar(for: agent)!
    let bitmap = NSBitmapImageRep(cgImage: avatar.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.1)
    precondition(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.9)
}

struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat
    var body: some View {
        Circle().fill(.blue.gradient).overlay(Text(String(agent.displayName.prefix(1))).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

private struct FixtureView: View {
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showDescriptions = false
    @StateObject private var completion = ComposerNameCompletion()
    @State private var draft = ""
    @State private var submissions = 0
    @State private var profile: AgentRecord?
    @State private var pendingReply: String?
    @State private var destination = "Group"
    @FocusState private var focused: Bool
    private let agents = [
        AgentRecord(displayName: "Angy", publicDescription: "Designs friendly interfaces."),
        AgentRecord(displayName: "Mara", publicDescription: "Reviews ideas and asks useful questions.", avatarImageData: fixtureAvatarData()),
        AgentRecord(displayName: "Mary Jane"),
        AgentRecord(displayName: "Ruby"),
        AgentRecord(displayName: "Tony"),
        AgentRecord(displayName: "Zoe")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(destination) — submissions: \(submissions)").font(.headline)
            Button("Show Mara's profile") { profile = agents[1] }
            Toggle("Show descriptions in the @ name menu", isOn: $showDescriptions)
            Spacer()
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                .background(ChatComposerBridge(isActive: focused, draft: draft, agents: agents,
                                               preferredIDs: [agents[1].id], completion: completion))
                .onSubmit { submissions += 1 }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
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
    init() { verifyNativeMenuPresentation() }
    var body: some Scene {
        WindowGroup("Chat Feature Tests") { FixtureView().preferredColorScheme(.dark) }
    }
}
