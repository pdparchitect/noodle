import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// Every group; a group's picture opens its profile.
struct GroupsSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var showsArchiveInfo = false
    private let archivedColumnWidth: CGFloat = 64

    private var groups: [BotConversation] { store.conversations.filter { $0.kind == .group } }

    var body: some View {
        Form {
            Section {
                if groups.isEmpty {
                    Text("No groups").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(groups) { group in
                            row(group)
                            if group.id != groups.last?.id { Divider() }
                        }
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                if !groups.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Archived") { showsArchiveInfo.toggle() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About archiving")
                            .help("About archiving")
                            .frame(width: archivedColumnWidth)
                            .popover(isPresented: $showsArchiveInfo) { GroupArchiveInfo() }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ group: BotConversation) -> some View {
        let hub = store.hubMirror(forConversation: group.id)
        let members = store.participants(for: group).map(\.displayName).joined(separator: ", ")
        return HStack(spacing: 12) {
            GroupProfileButton(group: group)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                Text([hub?.pairing.hub?.name, members.isEmpty ? nil : members].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hub groups are archived on their Hub, which cannot do it yet.
            if hub == nil {
                Toggle(isOn: Binding(get: { group.archivedAt != nil },
                                     set: { store.setArchived($0, conversationID: group.id) })) {
                    Text("Archived")
                }
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel("\(group.displayName), archived")
                .frame(width: archivedColumnWidth)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: archivedColumnWidth)
                    .accessibilityLabel("\(group.displayName), archiving unavailable")
            }
        }
    }

}

private struct GroupArchiveInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archived").font(.headline)
            Text("An archived group keeps its messages and attachments, but leaves the sidebar and takes no new messages. Its bots keep running in their other conversations.")
            Text("Turning this off brings the group back as it was.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
