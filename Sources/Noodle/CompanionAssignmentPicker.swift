import AppKit
import NoodleCore
import SwiftUI
import NoodleRuntimeSettings

struct CompanionAssignmentItem: Identifiable {
    let id: UUID
    let name: String
    let state: String
    let symbol: String
    let colour: Int
    var icon: Data?
    var detail: String?
    var tooltip: String { ["\(name) · \(state)", detail].compactMap { $0 }.joined(separator: "\n") }
}

/// The same assignment controls for Computer and Browser in the bot editor.
struct CompanionAssignmentPicker<Prompt: View, LibraryButton: View, Notice: View>: View {
    let title: String
    let noun: String
    let symbol: String
    let items: [CompanionAssignmentItem]
    @Binding var selectedIDs: Set<UUID>
    let createPrompt: Prompt
    let openLibraryButton: LibraryButton
    let notice: Notice
    var footer: String?
    var failure: String?
    @State private var showingAdd = false
    @State private var search = ""
    @State private var removing: CompanionAssignmentItem?

    private var selected: [CompanionAssignmentItem] {
        let known = items.filter { selectedIDs.contains($0.id) }
        let missing = selectedIDs.subtracting(items.map(\.id))
            .sorted { $0.uuidString < $1.uuidString }
            .map { CompanionAssignmentItem(id: $0, name: "Unavailable \(noun)", state: "Unavailable", symbol: "questionmark", colour: 0) }
        return known + missing
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button { search = ""; showingAdd = true } label: {
                    Label("Add \(title)", systemImage: "plus")
                }
                .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                    CompanionAssignmentChooser(title: title, items: items, selectedIDs: $selectedIDs,
                        search: $search, createPrompt: createPrompt, openLibraryButton: openLibraryButton,
                        onDone: { showingAdd = false })
                }
            }
            notice
            ScrollView {
                if selected.isEmpty {
                    if items.isEmpty { createPrompt.padding(.vertical, 24) }
                    else {
                        Button { search = ""; showingAdd = true } label: {
                            VStack(spacing: 10) {
                                Image(systemName: symbol).font(.largeTitle)
                                Text("Add \(title.lowercased()) to this bot")
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
                                .padding(.vertical, 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Add \(title.lowercased()) to this bot")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 16) {
                        ForEach(selected) { item in
                            VStack(spacing: 8) {
                                CompanionAssignmentAvatar(item: item, size: 48)
                                    .overlay(alignment: .topTrailing) {
                                        Button { removing = item } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 17)).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color(nsColor: .darkGray))
                                                .padding(4).contentShape(Circle())
                                        }.buttonStyle(.plain).offset(x: 10, y: -8)
                                            .help("Remove \(item.name) from bot")
                                            .accessibilityLabel("Remove \(item.name) from bot")
                                    }
                                Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity, alignment: .top)
                                .help(item.tooltip)
                        }
                    }.padding(12)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 280)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { item in
            Button("Remove \(noun.capitalized)", role: .destructive) { selectedIDs.remove(item.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This bot loses access to it when you save. The \(noun) itself is not deleted.")
        }
    }
}

struct CompanionAssignmentChooser<Prompt: View, LibraryButton: View>: View {
    let title: String
    let items: [CompanionAssignmentItem]
    @Binding var selectedIDs: Set<UUID>
    @Binding var search: String
    let createPrompt: Prompt
    let openLibraryButton: LibraryButton
    let onDone: () -> Void
    private var available: [CompanionAssignmentItem] {
        items.filter {
            !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.detail?.localizedCaseInsensitiveContains(search) == true)
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            TextField("Search \(title.lowercased())", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(available) { item in
                        Button { selectedIDs.insert(item.id) } label: {
                            HStack(spacing: 12) {
                                CompanionAssignmentAvatar(item: item, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.state).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }.padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(item.tooltip).accessibilityLabel("Add \(item.name) to bot")
                    }
                    if items.isEmpty { createPrompt }
                    else if available.isEmpty {
                        Text(search.isEmpty ? "All \(title.lowercased()) added" : "No matching \(title.lowercased())")
                            .foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack {
                if !items.isEmpty { openLibraryButton }
                Spacer()
                Button("Done", action: onDone)
            }
        }.padding(16).frame(width: 300, height: 280)
    }
}

private struct CompanionAssignmentAvatar: View {
    let item: CompanionAssignmentItem
    let size: CGFloat
    var body: some View {
        var agent = AgentRecord(displayName: item.name, accentSeed: 0)
        agent.avatarSymbolName = item.symbol
        agent.avatarColorIndex = abs(item.colour % BotAvatarPalette.gradients.count)
        agent.avatarImageData = item.icon
        return BotAvatar(agent: agent, size: size)
    }
}
