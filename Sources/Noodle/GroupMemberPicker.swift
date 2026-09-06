import SwiftUI
import NoodleCore

/// The same add/remove interface is used when creating and editing a group.
struct GroupMemberPicker: View {
    let agents: [AgentRecord]
    @Binding var selectedIDs: Set<UUID>
    @State private var showingAdd = false
    @State private var search = ""

    private var selected: [AgentRecord] { agents.filter { selectedIDs.contains($0.id) } }
    private var available: [AgentRecord] {
        agents.filter {
            !selectedIDs.contains($0.id) &&
                (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: {
                    Label("Add Bots", systemImage: "plus")
                }
                .disabled(selected.count == agents.count)
                .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
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
                        HStack { Spacer(); Button("Done") { showingAdd = false } }
                    }
                    .padding(16)
                    .frame(width: 300, height: 280)
                }
            }
            ScrollView {
                if selected.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle)
                        Text("Add bots to this group")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 16) {
                        ForEach(selected) { agent in
                            VStack(spacing: 8) {
                                BotAvatar(agent: agent, size: 48)
                                    .overlay(alignment: .topTrailing) {
                                        Button { selectedIDs.remove(agent.id) } label: {
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
            .frame(minHeight: 140, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
