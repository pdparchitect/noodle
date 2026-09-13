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
                            Toggle(isOn: Binding(
                                get: { store.runtime.accessConfiguration.isExtended(for: agent) },
                                set: { enabled in
                                    store.runtime.setExtendedAccess(enabled, agent: agent, repository: store.repository)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.displayName).font(.body)
                                    if requiresAutonomousAccess, let provider {
                                        Text("Autonomous access · Required by \(provider.displayName)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(store.runtime.changingAccess.contains(agent.id) ? "Restarting runtime…" : (store.runtime.accessConfiguration.isExtended(for: agent) ? "Autonomous access" : "Restricted"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .controlSize(.mini)
                            .accessibilityLabel("\(agent.displayName), autonomous access")
                            .disabled((requiresAutonomousAccess && store.runtime.accessConfiguration.isExtended(for: agent)) || store.runtime.changingAccess.contains(agent.id))
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
                Text("Codex, FX, Grok Build, and Apple start restricted and let you choose autonomous access. Claude Code and Muse Code require autonomous access; selecting one in the bot editor authorizes it. Copied bots may need access enabled here.")
            }
        }
        .formStyle(.grouped)
    }
}
