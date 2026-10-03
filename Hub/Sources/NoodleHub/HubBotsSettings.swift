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
            if agent.archivedAt != nil {
                ArchivedTag()
            } else {
                SettingsStatusLabel(title: snapshot.phase.title, systemImage: "circle.fill", color: snapshot.phase.color)
                    .help(snapshot.detail)
            }
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

/// Every group kept on the Hub, whose it is and its bots, with an Archived switch as in Noodle.
struct HubGroupsSettingsView: View {
    let host: HubSettingsHost
    private let archivedColumnWidth: CGFloat = 64

    var body: some View {
        // Groups come and go from paired devices, so the list is reread while it is open.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let groups = (try? host.hub.bots.everyGroup()) ?? []
            let agents = host.agents
            Form {
                Section {
                    if groups.isEmpty {
                        Text("No groups").foregroundStyle(.secondary)
                    } else {
                        let owners = Dictionary(uniqueKeysWithValues: groups.map { ($0.conversation.id, $0.owner) })
                        SettingsRowList(groups.map(\.conversation)) { group in
                            row(group, owner: owners[group.id] ?? nil, agents: agents)
                        }
                    }
                } header: {
                    if !groups.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            Text("Archived").frame(width: archivedColumnWidth)
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ group: BotConversation, owner: UUID?, agents: [AgentRecord]) -> some View {
        let ownerName = owner.flatMap { id in host.hub.access.users.first { $0.id == id }?.name }
        let members = group.participantIDs.compactMap { id in agents.first { $0.id == id }?.displayName }.joined(separator: ", ")
        return HStack(spacing: 12) {
            HubGroupProfileButton(host: host, group: group, owner: ownerName, members: members)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName).lineLimit(1)
                Text([ownerName, members.isEmpty ? nil : members].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: Binding(get: { group.archivedAt != nil }, set: { host.setArchived($0, id: group.id) })) {
                Text("Archived")
            }
            .labelsHidden()
            .controlSize(.mini)
            .accessibilityLabel("\(group.displayName), archived")
            .frame(width: archivedColumnWidth)
        }
    }
}

/// A group's picture, opening its profile as a bot's does: whose it is, what it is for, its bots,
/// and its folder.
private struct HubGroupProfileButton: View {
    let host: HubSettingsHost
    let group: BotConversation
    let owner: String?
    let members: String
    @State private var showsProfile = false

    var body: some View {
        Button { showsProfile = true } label: {
            GroupPicture(size: 32).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show \(group.displayName)’s profile")
        .accessibilityLabel("Show profile for \(group.displayName)")
        .popover(isPresented: $showsProfile, arrowEdge: .leading) { profile }
    }

    private var profile: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { showsProfile = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close group profile")
            }
            GroupPicture(size: 88)
            VStack(spacing: 4) {
                Text(group.displayName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let owner { Text(owner).foregroundStyle(.secondary) }
            }
            if group.archivedAt != nil { ArchivedTag() }
            VStack(spacing: 8) {
                Text(group.publicDescription?.isEmpty == false ? group.publicDescription! : "No description yet.")
                    .foregroundStyle(.secondary)
                if !members.isEmpty { Text(members).font(.caption).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([host.repository.conversationDirectory(id: group.id)])
                showsProfile = false
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 18)).frame(height: 20)
                    Text("Folder").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Folder")
            .accessibilityLabel("Show Folder")
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct GroupPicture: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "person.3.fill")
            .font(.system(size: size * 0.4))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Marks an archived bot or group in its profile, as Noodle does.
private struct ArchivedTag: View {
    var body: some View {
        Text("Archived")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
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
