import SwiftUI
import NoodleCore

public struct AgentAccessSettingsView: View {
    let store: any BotSettingsHost
    @State private var showsAccessInfo = false
    @State private var showsAppsInfo = false
    @State private var confirming: AccessConfirmation?
    private let accessColumnWidth: CGFloat = 100
    private let appsColumnWidth: CGFloat = 64

    public var body: some View {
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
                            store.botProfileButton(agent)
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
                                get: { store.runtime.accessConfiguration.isExtended(for: agent) || confirming == .init(agent: agent, kind: .unrestricted) },
                                set: { enabled in
                                    if enabled {
                                        confirming = .init(agent: agent, kind: .unrestricted)
                                    } else {
                                        store.runtime.setExtendedAccess(false, agent: agent, repository: store.repository)
                                    }
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
                                    get: { store.runtime.accessConfiguration.appsEnabled(for: agent) || confirming == .init(agent: agent, kind: .apps) },
                                    set: { enabled in
                                        if enabled {
                                            confirming = .init(agent: agent, kind: .apps)
                                        } else {
                                            store.runtime.setAppsEnabled(false, agent: agent, repository: store.repository)
                                        }
                                    }
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
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { request in
            Button(request.kind == .unrestricted ? "Allow Unrestricted Access" : "Allow Apps") {
                switch request.kind {
                case .unrestricted: store.runtime.setExtendedAccess(true, agent: request.agent, repository: store.repository)
                case .apps: store.runtime.setAppsEnabled(true, agent: request.agent, repository: store.repository)
                }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { request in
            Text(request.message)
        }
    }

    public init(store: any BotSettingsHost) {
        self.store = store
    }
}

private struct AccessConfirmation: Equatable {
    enum Kind { case unrestricted, apps }
    let agent: AgentRecord
    let kind: Kind

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.agent.id == rhs.agent.id && lhs.kind == rhs.kind }

    var title: String {
        kind == .unrestricted ? "Allow Unrestricted Access for \(agent.displayName)?" : "Allow Apps for \(agent.displayName)?"
    }

    var message: String {
        switch kind {
        case .unrestricted:
            "\(agent.displayName) will be able to read and change files and use services beyond its private workspace, with the access available to your Mac account. This restarts the bot."
        case .apps:
            "\(agent.displayName) will be able to use apps connected to your \(AgentAppsInfo.account(for: HarnessProvider(rawValue: agent.harnessIdentifier ?? ""))) account, such as Gmail, Google Drive, and Calendar, with the permissions you granted there. This restarts the bot."
        }
    }
}

private struct AgentAccessStatusLabel: View {
    let isExtended: Bool
    let isChanging: Bool
    let requiredProvider: HarnessProvider?
    @State private var showsAccessInfo = false

    private var title: String { isExtended ? "unrestricted" : "restricted" }

    public var body: some View {
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

    public var body: some View {
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

    public var body: some View {
        Button("apps") { showsInfo.toggle() }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("About account apps")
            .popover(isPresented: $showsInfo) { AgentAppsInfo(provider: provider) }
    }
}

private struct AgentAppsInfo: View {
    let provider: HarnessProvider?

    private var account: String { Self.account(for: provider) }

    static func account(for provider: HarnessProvider?) -> String {
        switch provider {
        case .codex: "ChatGPT"
        case .claudeCode: "Claude.ai"
        default: "ChatGPT or Claude.ai"
        }
    }

    public var body: some View {
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
