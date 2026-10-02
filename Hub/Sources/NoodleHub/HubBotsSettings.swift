import AppKit
import HubCore
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import SwiftUI

/// A bot's avatar in Settings > Bots, opening its profile: whose it is, how it is doing,
/// and its folder, activity and New Session.
struct HubBotProfileButton: View {
    let host: HubSettingsHost
    let agent: AgentRecord
    @State private var showsProfile = false
    @State private var newSessionAgent: AgentRecord?

    var body: some View {
        Button { showsProfile = true } label: {
            BotAvatar(agent: agent, size: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show \(agent.displayName)’s profile")
        .accessibilityLabel("Show profile for \(agent.displayName)")
        .popover(isPresented: $showsProfile, arrowEdge: .leading) { profile }
        .modifier(NewSessionConfirmation(store: host, agent: $newSessionAgent))
    }

    private var profile: some View {
        let snapshot = host.runtime.snapshot(for: agent.id)
        let owner = host.hub.access.owner(ofBot: agent.id).flatMap { id in host.hub.access.users.first { $0.id == id }?.name }
        return VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { showsProfile = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close bot profile")
            }
            BotAvatar(agent: agent, size: 88)
            VStack(spacing: 4) {
                Text(agent.displayName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text([owner, agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.displayName]
                        .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            SettingsStatusLabel(title: snapshot.phase.title, systemImage: "circle.fill", color: snapshot.phase.color)
                .help(snapshot.detail)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([host.repository.directory(for: agent)])
                    showsProfile = false
                } label: {
                    actionLabel("Folder", systemImage: "folder")
                }
                .help("Show Folder")
                .accessibilityLabel("Show Folder")
                Divider().frame(height: 32).accessibilityHidden(true)
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    host.activityWindows.show(agent: agent, log: host.runtime.activity.log(for: agent.id))
                    showsProfile = false
                } label: {
                    actionLabel("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Activity")
                .accessibilityLabel("Activity")
                Divider().frame(height: 32).accessibilityHidden(true)
                Button {
                    showsProfile = false
                    // Let the popover close before the confirmation is presented.
                    DispatchQueue.main.async { newSessionAgent = agent }
                } label: {
                    actionLabel("New Session", systemImage: "arrow.counterclockwise")
                }
                .help("New Session")
                .accessibilityLabel("New Session")
                .disabled(host.runtime.changingAccess.contains(agent.id))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(height: 20)
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
