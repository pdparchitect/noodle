import SwiftUI
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings

/// The steps the welcome brings up under the wordmark: the shared steps, with a Noodle Hub before the accounts.
struct FirstBotSetupSheet: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue
    @State private var joiningHub = false
    /// The Hubs joined before the join sheet opened.
    @State private var hubsBeforeJoining = 0
    let setup: HarnessSetupController
    let runtime: AgentRuntimeCoordinator

    var body: some View {
        FirstBotSetupSteps(
            setup: setup, runtime: runtime,
            makeTeam: { id in
                guard let made = store.createStarterTeamIfFirst(on: id, style: nameStyle) else { return nil }
                return (made, store.selectedConversation?.kind == .group ? store.selectedConversationID : nil)
            },
            introduce: { store.introduceStarterTeam(in: $0) },
            finish: { store.finishFirstBotSetup() },
            picture: { AnyView(BotAvatar(agent: $0, size: 64)) },
            roles: StarterTeam.members.map(\.role)
        ) { hubTile }
        // The Hub's harnesses are enough to make bots, so joining one finishes the welcome.
        .sheet(isPresented: $joiningHub, onDismiss: {
            if store.hubs.hubs.count > hubsBeforeJoining { store.finishFirstBotSetup() }
        }) {
            HubJoinSheet().environment(store)
        }
    }

    /// Instead of an account here, the harnesses a Noodle Hub lends.
    private var hubTile: some View {
        Button {
            store.hubs.clearJoinError()
            hubsBeforeJoining = store.hubs.hubs.count
            joiningHub = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text("Hub").font(.headline)
                    Text("by invitation").font(.caption).foregroundStyle(.secondary)
                }
                if store.hubs.hubs.isEmpty {
                    SettingsStatusLabel(title: "Not joined", systemImage: "minus.circle", color: .secondary)
                } else {
                    SettingsStatusLabel(title: "Joined", systemImage: "checkmark.circle.fill", color: .green)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Use the harnesses a Noodle Hub lends you")
        .accessibilityLabel("Join a Noodle Hub")
    }

    private var nameStyle: BotNameStyle { BotNameStyle(rawValue: botNameStyle) ?? .real }
}
