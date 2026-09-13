import SwiftUI
import NoodleCore

struct AgentAccessSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        Form {
            Section {
                if store.agents.isEmpty {
                    Text("No bots")
                        .foregroundStyle(.secondary)
                } else {
                    SettingsBotList(agents: store.agents) { agent in
                        let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")
                        let requiresAutonomousAccess = provider?.supportsRestrictedAccess == false
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.displayName).font(.body)
                                    AgentAccessStatusLabel(
                                        isExtended: store.runtime.accessConfiguration.isExtended(for: agent),
                                        isChanging: store.runtime.changingAccess.contains(agent.id),
                                        requiredProvider: requiresAutonomousAccess ? provider : nil
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Toggle(isOn: Binding(
                                    get: { store.runtime.accessConfiguration.isExtended(for: agent) },
                                    set: { enabled in
                                        store.runtime.setExtendedAccess(enabled, agent: agent, repository: store.repository)
                                    }
                                )) {
                                    Text(agent.displayName)
                                }
                                .labelsHidden()
                                .controlSize(.mini)
                                .accessibilityLabel("\(agent.displayName), autonomous access")
                                .disabled((requiresAutonomousAccess && store.runtime.accessConfiguration.isExtended(for: agent)) || store.runtime.changingAccess.contains(agent.id))
                            }
                            if store.runtime.snapshot(for: agent.id).phase == .failed {
                                Text(store.runtime.snapshot(for: agent.id).detail)
                                    .font(.caption).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Button("Retry Startup") {
                                    store.runtime.restart(agent: agent, repository: store.repository)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Retry startup for \(agent.displayName)")
                                .disabled(store.runtime.changingAccess.contains(agent.id))
                            }
                        }
                    }
                }
            } footer: {
                Text("Codex, FX, Grok Build, Muse Code, and Apple start restricted and let you choose autonomous access. Claude Code requires autonomous access; selecting it in the bot editor authorizes it. Copied bots may need access enabled here.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentAccessStatusLabel: View {
    let isExtended: Bool
    let isChanging: Bool
    let requiredProvider: HarnessProvider?
    @State private var showsAccessInfo = false

    private var title: String { isExtended ? "Autonomous access" : "Restricted" }

    var body: some View {
        if isChanging {
            Text("Restarting runtime…")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Group {
                if let requiredProvider {
                    Button(title) { showsAccessInfo.toggle() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(isExtended ? Color.orange : Color.secondary)
                        .help("Why does \(requiredProvider.displayName) require autonomous access?")
                        .accessibilityHint("Show why \(requiredProvider.displayName) requires autonomous access")
                        .popover(isPresented: $showsAccessInfo) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Autonomous access")
                                    .font(.headline)
                                Text("\(requiredProvider.displayName) requires autonomous access and can work beyond this bot’s private workspace. Selecting it in the bot editor authorizes this access.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(20)
                            .frame(width: 360, alignment: .leading)
                        }
                } else {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(isExtended ? Color.orange : Color.secondary)
                }
            }
        }
    }
}
