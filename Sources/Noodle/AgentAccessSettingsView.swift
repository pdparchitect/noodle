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
                        let requiresUnrestrictedAccess = provider?.supportsRestrictedAccess == false
                        HStack(alignment: .top, spacing: 12) {
                            AgentProfileButton(agent: agent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.displayName).font(.body)
                                AgentAccessStatusLabel(
                                    isExtended: store.runtime.accessConfiguration.isExtended(for: agent),
                                    isChanging: store.runtime.changingAccess.contains(agent.id),
                                    requiredProvider: requiresUnrestrictedAccess ? provider : nil
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
                            .accessibilityLabel("\(agent.displayName), unrestricted access")
                            .disabled((requiresUnrestrictedAccess && store.runtime.accessConfiguration.isExtended(for: agent)) || store.runtime.changingAccess.contains(agent.id))
                        }
                    }
                }
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

    private var title: String { isExtended ? "Unrestricted" : "Restricted" }

    private var explanation: String {
        if isExtended {
            "This bot can read and change files and use services beyond its private workspace, with the access available to your Mac account. macOS and tool permissions still apply. Noodle approves supported tool requests automatically."
        } else {
            "This bot runs in a macOS filesystem sandbox. It can work in its private workspace and use allowed harness storage, while unrelated personal files are blocked. Assigned tools and computers use their own permissions."
        }
    }

    var body: some View {
        if isChanging {
            Text("Restarting runtime…")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button(title) { showsAccessInfo.toggle() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(isExtended ? Color.orange : Color.secondary)
                .help("About \(title.lowercased()) access")
                .accessibilityHint("Show what \(title.lowercased()) access allows")
                .popover(isPresented: $showsAccessInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)
                        Text(explanation)
                            .fixedSize(horizontal: false, vertical: true)
                        if let requiredProvider {
                            Text("\(requiredProvider.displayName) requires unrestricted access. Selecting it in the bot editor authorizes this access.")
                                .fixedSize(horizontal: false, vertical: true)
                        } else if isExtended {
                            Text("Turning this off restarts the bot in Restricted mode. It does not undo completed actions or revoke macOS permissions.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(width: 360, alignment: .leading)
                }
        }
    }
}
