import SwiftUI
import NoodleCore

/// Deliberately uses only the public record, never the workspace/backstory.
struct AgentProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    let canOpenDirectMessage: Bool
    let reply: () -> Void
    let directMessage: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close bot profile")
            }
            BotAvatar(agent: agent, size: 88)
            Text(agent.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            ScrollView {
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 120)
            VStack(spacing: 10) {
                Button(action: reply) {
                    Label("Reply in Group", systemImage: "arrowshape.turn.up.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: directMessage) {
                    Label("Direct Message", systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canOpenDirectMessage)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var description: String {
        let value = agent.publicDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No description yet." : value
    }
}
