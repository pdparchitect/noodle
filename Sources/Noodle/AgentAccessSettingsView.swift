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
                    ForEach(store.agents) { agent in
                        Toggle(isOn: Binding(
                            get: { store.runtime.accessConfiguration.isExtended(agent.id) },
                            set: { enabled in
                                store.runtime.setExtendedAccess(enabled, agent: agent, repository: store.repository)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.displayName)
                                Text(store.runtime.changingAccess.contains(agent.id) ? "Restarting runtime…" : (store.runtime.accessConfiguration.isExtended(agent.id) ? "Autonomous access" : "Restricted"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("\(agent.displayName), autonomous access")
                        .disabled(store.runtime.changingAccess.contains(agent.id))
                        if store.runtime.snapshot(for: agent.id).phase == .failed {
                            VStack(alignment: .leading, spacing: 8) {
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
                Text("New bots start in restricted mode. Turn on autonomous access for a bot that needs access beyond its private workspace. Claude Code, FX, Grok Build and Muse Code currently require autonomous access. Existing bots keep their access settings.")
            }
        }
        .formStyle(.grouped)
    }
}
