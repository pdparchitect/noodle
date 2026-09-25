import AppKit
import HubCore
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import SwiftUI

/// Every bot kept on the Hub, whose it is and how it is doing, with its folder and activity a click away.
struct HubBotsSettingsView: View {
    let host: HubSettingsHost

    var body: some View {
        // Bots come and go from paired devices, so the list is reread while it is open.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let agents = host.agents
            Form {
                Section {
                    if agents.isEmpty {
                        Text("No bots").foregroundStyle(.secondary)
                    }
                    ForEach(agents) { agent in
                        row(agent)
                    }
                } header: {
                    Text("Bots")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ agent: AgentRecord) -> some View {
        let snapshot = host.runtime.snapshot(for: agent.id)
        let owner = host.hub.access.owner(ofBot: agent.id).flatMap { id in host.hub.access.users.first { $0.id == id }?.name }
        return HStack(spacing: 10) {
            BotAvatar(agent: agent, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).lineLimit(1)
                Text([owner, agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.displayName]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            SettingsStatusLabel(title: snapshot.phase.title, systemImage: "circle.fill", color: snapshot.phase.color)
                .help(snapshot.detail)
            Button("Show Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([host.repository.directory(for: agent)])
            }
            Button("Activity") {
                NSApp.activate()
                host.activityWindows.show(agent: agent, log: host.runtime.activity.log(for: agent.id))
            }
        }
    }
}

private extension AgentRuntimePhase {
    var title: String {
        switch self {
        case .offline: "Offline"
        case .starting: "Starting"
        case .ready: "Ready"
        case .working: "Working"
        case .failed: "Failed"
        default: rawValue.capitalized
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .working: .blue
        case .failed: .red
        default: .secondary
        }
    }
}
