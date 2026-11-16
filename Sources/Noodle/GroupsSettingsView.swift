import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// Settings › Groups in every app: each group with an Archived switch. The app gives each group's picture, the line
/// under its name, and the switch, or nil where the group is archived elsewhere, such as on its Hub.
struct GroupsSettingsList: View {
    let groups: [BotConversation]
    /// What the app calls a group's members, for the note on archiving.
    let members: String
    let picture: (BotConversation) -> AnyView
    let subtitle: (BotConversation) -> String
    let archived: (BotConversation) -> Binding<Bool>?
    @State private var showsArchiveInfo = false
    private let archivedColumnWidth: CGFloat = 64

    var body: some View {
        Form {
            Section {
                if groups.isEmpty {
                    Text("No groups").foregroundStyle(.secondary)
                } else {
                    SettingsRowList(groups) { group in row(group) }
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
                            .popover(isPresented: $showsArchiveInfo) { GroupArchiveInfo(members: members) }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ group: BotConversation) -> some View {
        let subtitle = subtitle(group)
        return HStack(spacing: 12) {
            picture(group)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let archived = archived(group) {
                Toggle(isOn: archived) { Text("Archived") }
                    .labelsHidden()
                    .controlSize(.mini)
                    .accessibilityLabel("\(group.displayName), archived")
                    .frame(width: archivedColumnWidth)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: archivedColumnWidth)
                    .accessibilityLabel("\(group.displayName), archived on its Hub")
            }
        }
    }
}

private struct GroupArchiveInfo: View {
    let members: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archived").font(.headline)
            Text("An archived group keeps its messages and attachments, but leaves the sidebar and takes no new messages. Its \(members) keep running in their other conversations.")
            Text("Turning this off brings the group back as it was.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
