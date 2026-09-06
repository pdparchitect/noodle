import SwiftUI
import NoodleCore

struct NoodleSettingsView: View {
    var body: some View {
        TabView {
            HarnessesSettingsView()
                .tabItem {
                    Label("Harnesses", systemImage: "terminal")
                }
            HeartbeatsSettingsView()
                .tabItem {
                    Label("Heartbeats", systemImage: "waveform.path.ecg")
                }
            AgentAccessSettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            #if DEBUG
            DeveloperSettingsView()
                .tabItem { Label("Dev", systemImage: "hammer") }
            #endif
        }
        .frame(width: 580, height: 380)
    }
}

private struct HeartbeatsSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle("Wake idle agents", isOn: Binding(
                    get: { store.runtime.heartbeatConfiguration.isEnabled },
                    set: { store.runtime.configureHeartbeats(enabled: $0) }
                ))
                Stepper(value: Binding(
                    get: { store.runtime.heartbeatConfiguration.intervalMinutes },
                    set: { store.runtime.configureHeartbeats(intervalMinutes: $0) }
                ), in: 1...1_440) {
                    Text("After \(store.runtime.heartbeatConfiguration.intervalMinutes) minutes without activity")
                }
                .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
            } footer: {
                Text("Each bot has its own timer. Incoming messages, replies, reactions, and agent work reset it. Heartbeats wait until the agent is idle and only run while Noodle is open. Changing these settings starts a fresh interval.")
            }
            if !store.agents.isEmpty {
                Section("Bots") {
                    ForEach(store.agents) { agent in
                        Toggle(agent.displayName, isOn: Binding(
                            get: { !store.runtime.heartbeatConfiguration.disabledAgentIDs.contains(agent.id) },
                            set: { store.runtime.setHeartbeatEnabled($0, for: agent.id) }
                        ))
                    }
                }
                .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
            }
            Text("A heartbeat starts an agent turn and may use tokens. Agents should stay quiet unless they have useful work or an update.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct HarnessesSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.runtime.availableInstallations.isEmpty {
                ContentUnavailableView {
                    Label("No Harnesses Detected", systemImage: "terminal")
                } description: {
                    Text("Install a supported harness, then check again.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Detected Harnesses") {
                        ForEach(store.runtime.availableInstallations) { installation in
                            HarnessInstallationRow(installation: installation)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                if store.runtime.isRefreshingInstallations {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for harnesses")
                }
                Button("Check Again") {
                    Task { await store.runtime.refreshInstallations() }
                }
                .disabled(store.runtime.isRefreshingInstallations)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task {
            await store.runtime.refreshInstallations()
        }
    }
}

private struct HarnessInstallationRow: View {
    let installation: HarnessInstallation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installation.provider.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(installation.provider.displayName)
                        .fontWeight(.semibold)
                    Spacer()
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let path = installation.executablePath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
