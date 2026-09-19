import SwiftUI
import NoodleCore

struct AgentAccessSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var showsAccessInfo = false
    @State private var showsAppsInfo = false
    private let accessColumnWidth: CGFloat = 100
    private let appsColumnWidth: CGFloat = 64

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
                                HStack(spacing: 4) {
                                    AgentAccessStatusLabel(
                                        isExtended: store.runtime.accessConfiguration.isExtended(for: agent),
                                        isChanging: store.runtime.changingAccess.contains(agent.id),
                                        requiredProvider: requiresUnrestrictedAccess ? provider : nil
                                    )
                                    if store.runtime.accessConfiguration.appsEnabled(for: agent),
                                       !store.runtime.changingAccess.contains(agent.id) {
                                        Text("·").foregroundStyle(.secondary)
                                        AgentAppsStatusLabel(provider: provider)
                                    }
                                }
                                .font(.caption)
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
                            .frame(width: accessColumnWidth)

                            if provider?.supportsAccountApps == true {
                                Toggle(isOn: Binding(
                                    get: { store.runtime.accessConfiguration.appsEnabled(for: agent) },
                                    set: { store.runtime.setAppsEnabled($0, agent: agent, repository: store.repository) }
                                )) { Text("Apps") }
                                .labelsHidden()
                                .controlSize(.mini)
                                .accessibilityLabel("\(agent.displayName), account apps")
                                .help(provider == .codex ? "Allow apps connected to ChatGPT" : "Allow connectors from Claude.ai")
                                .disabled(store.runtime.changingAccess.contains(agent.id))
                                .frame(width: appsColumnWidth)
                            } else {
                                Text("—")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: appsColumnWidth)
                                    .accessibilityLabel("\(agent.displayName), account apps unavailable")
                            }
                        }
                    }
                }
            } header: {
                if !store.agents.isEmpty {
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button("Unrestricted") { showsAccessInfo.toggle() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About unrestricted access")
                            .help("About unrestricted access")
                            .frame(width: accessColumnWidth)
                            .popover(isPresented: $showsAccessInfo) { AgentAccessInfo(isExtended: true) }
                        Button("Apps") { showsAppsInfo.toggle() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About account apps")
                            .help("About account apps")
                            .frame(width: appsColumnWidth)
                            .popover(isPresented: $showsAppsInfo) { AgentAppsInfo(provider: nil) }
                    }
                    .font(.caption)
                    .textCase(nil)
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

    private var title: String { isExtended ? "unrestricted" : "restricted" }

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
                    AgentAccessInfo(isExtended: isExtended, requiredProvider: requiredProvider)
                }
        }
    }
}

private struct AgentAccessInfo: View {
    let isExtended: Bool
    var requiredProvider: HarnessProvider? = nil

    private var explanation: String {
        if isExtended {
            "This bot can read and change files and use services beyond its private workspace, with the access available to your Mac account. macOS and tool permissions still apply. Noodle approves supported tool requests automatically."
        } else {
            "This bot runs in a macOS filesystem sandbox. It can work in its private workspace, the folders added in Edit Bot, and allowed harness storage, while unrelated personal files are blocked. Assigned tools and computers use their own permissions."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isExtended ? "Unrestricted" : "Restricted").font(.headline)
            Text(explanation)
            if let requiredProvider {
                Text("\(requiredProvider.displayName) requires unrestricted access. Selecting it in the bot editor authorizes this access.")
            } else if isExtended {
                Text("Off by default. Changing this restarts the bot. Turning it off restores Restricted mode; it does not undo completed actions or revoke macOS permissions.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}

private struct AgentAppsStatusLabel: View {
    let provider: HarnessProvider?
    @State private var showsInfo = false

    var body: some View {
        Button("apps") { showsInfo.toggle() }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("About account apps")
            .popover(isPresented: $showsInfo) { AgentAppsInfo(provider: provider) }
    }
}

private struct AgentAppsInfo: View {
    let provider: HarnessProvider?

    private var account: String {
        switch provider {
        case .codex: "ChatGPT"
        case .claudeCode: "Claude.ai"
        default: "ChatGPT or Claude.ai"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps").font(.headline)
            Text("Allows the bot to use apps connected to your \(account) account, such as Gmail, Google Drive, and Calendar, with the permissions you granted there.")
            Text("Off by default. Changing this restarts the bot. Turning it off keeps those services connected to your account.")
            Text("Tools assigned through Noodle are controlled separately. This does not change Restricted or Unrestricted access.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
