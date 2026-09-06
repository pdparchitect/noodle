import SwiftUI
import NoodleCore

struct AgentAccessSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var confirmingAgent: AgentRecord?

    var body: some View {
        Form {
            Section {
                Text("Restricted access is the default. Enable extended access only for bots you trust with your Mac.")
                ForEach(store.agents) { agent in
                    Toggle(isOn: Binding(
                        get: { store.runtime.accessConfiguration.isExtended(agent.id) },
                        set: { enabled in
                            if enabled { confirmingAgent = agent }
                            else { store.runtime.setExtendedAccess(false, agent: agent, repository: store.repository) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.displayName)
                            Text(store.runtime.changingAccess.contains(agent.id) ? "Restarting runtime…" : (store.runtime.accessConfiguration.isExtended(agent.id) ? "Extended access" : "Restricted"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(agent.displayName), extended access")
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
            } footer: {
                Text("Extended agents run in a signed helper outside the app sandbox. Codex still restricts shell commands and asks for additional permissions in chat. Connected tools may have their own access, including signed-in browser sessions; not every tool action produces a Codex approval prompt. macOS privacy permissions still apply.")
            }
        }
        .formStyle(.grouped)
        .alert("Enable extended access?", isPresented: Binding(
            get: { confirmingAgent != nil },
            set: { if !$0 { confirmingAgent = nil } }
        ), presenting: confirmingAgent) { agent in
            Button("Cancel", role: .cancel) { confirmingAgent = nil }
            Button("Enable for \(agent.displayName)") {
                store.runtime.setExtendedAccess(true, agent: agent, repository: store.repository)
                confirmingAgent = nil
            }
        } message: { agent in
            Text("\(agent.displayName) will run outside Noodle’s App Sandbox and may access files, connected tools, and signed-in browser sessions beyond its workspace. Heartbeats use this same access. Additional permissions requested by Codex wait for your approval. Switching modes stops current work and starts a separate harness session; chat history and workspace stay intact. You can turn this off here at any time.")
        }
    }
}
