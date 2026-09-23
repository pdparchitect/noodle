import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// The same add/remove interface is used when creating and editing a group.
struct GroupMemberPicker: View {
    let agents: [AgentRecord]
    @Binding var selectedIDs: Set<UUID>
    @State private var showingAdd = false
    @State private var search = ""
    @State private var memberPendingRemoval: AgentRecord?

    private var selected: [AgentRecord] { agents.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members").font(.caption.weight(.semibold))
                Spacer()
                Button { search = ""; showingAdd = true } label: {
                    Label("Add Bots", systemImage: "plus")
                }
                .disabled(selected.count == agents.count)
                .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                    GroupMemberChooser(agents: agents, selectedIDs: $selectedIDs, search: $search) {
                        showingAdd = false
                    }
                }
            }
            ScrollView {
                if selected.isEmpty {
                    Button { search = ""; showingAdd = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle)
                            Text("Add bots to this group")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(agents.isEmpty)
                    .help("Add Bots")
                    .accessibilityLabel("Add bots to this group")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 16) {
                        ForEach(selected) { agent in
                            VStack(spacing: 8) {
                                AgentProfileButton(agent: agent, size: 48, showsShadow: true,
                                    opensMessageInSeparateWindow: true)
                                    .overlay(alignment: .topTrailing) {
                                        Button { memberPendingRemoval = agent } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 17))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color(nsColor: .darkGray))
                                                .padding(4)
                                                .contentShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: 10, y: -8)
                                        .help("Remove \(agent.displayName) from group")
                                        .accessibilityLabel("Remove \(agent.displayName) from group")
                                    }
                                Text(agent.displayName)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(12)
                }
            }
            // Grow with a few rows, then scroll rather than pushing the sheet's
            // header and action buttons outside the available window.
            .frame(minHeight: 140, maxHeight: 280)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .confirmationDialog(
            "Remove \(memberPendingRemoval?.displayName ?? "bot") from group?",
            isPresented: Binding(
                get: { memberPendingRemoval != nil },
                set: { if !$0 { memberPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: memberPendingRemoval
        ) { agent in
            Button("Remove from Group", role: .destructive) { selectedIDs.remove(agent.id) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct GroupMemberChooser: View {
    let agents: [AgentRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var search: String
    let onDone: () -> Void

    private var selected: [AgentRecord] { agents.filter { selectedIDs.contains($0.id) } }
    private var available: [AgentRecord] {
        agents.filter {
            !selectedIDs.contains($0.id) &&
                (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            TextField("Search bots", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(available) { agent in
                        Button {
                            selectedIDs.insert(agent.id)
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(agent: agent, size: 32)
                                Text(agent.displayName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(agent.displayName) to group")
                    }
                    if available.isEmpty {
                        Text(selected.count == agents.count ? "All bots added" : "No matching bots")
                            .foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack { Spacer(); Button("Done", action: onDone) }
        }
        .padding(16)
        .frame(width: 300, height: 280)
    }
}
