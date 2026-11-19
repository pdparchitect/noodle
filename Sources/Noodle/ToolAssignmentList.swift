import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// The Tools tab of a bot's or agent's editor in every app: the saved tool connections it may use, added from a
/// searchable chooser, edited or removed, and a new one made in place. Saved connections, their setup and
/// sign-in are shared with Settings; this only drafts the grants. The app adds tools of its own as `extraRows`,
/// and offers them in the chooser as `chooserExtras`, given the search.
struct ToolAssignmentList<Rows: View, Extras: View>: View {
    let controller: ToolConnectionsController
    @Binding var selectedIDs: Set<UUID>
    /// What the app calls the one getting the tools, such as "bot".
    let member: String
    /// Whether the app's own rows show anything, so the list is not empty.
    var hasExtraRows = false
    @ViewBuilder var extraRows: () -> Rows
    @ViewBuilder var chooserExtras: (String) -> Extras
    @State private var showingAdd = false
    @State private var search = ""
    @State private var wantsNewTool = false
    @State private var showingNewTool = false
    @State private var editing: ToolConnection?
    @State private var removing: ToolConnection?
    /// Room for five tools, so the sheet does not jump as they are added or removed.
    private static var listHeight: CGFloat { 5 * 44 }

    private var known: Set<UUID> { Set(controller.registry.connections.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                        chooser
                            .onDisappear {
                                // Wait for the popover to close before presenting a sheet
                                // on the editor. No nested popover or global window.
                                if wantsNewTool { wantsNewTool = false; showingNewTool = true }
                            }
                    }
            }
            if selectedIDs.isEmpty && !hasExtraRows {
                Button { search = ""; showingAdd = true } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                        Text("Add tools to this \(member)")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: Self.listHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Add tools to this \(member)")
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(controller.registry.connections.filter { selectedIDs.contains($0.id) }) { connection in
                            HStack(spacing: 10) {
                                ToolConnectionIcon(connection: connection, size: 26)
                                Text(connection.name).lineLimit(1)
                                ToolConnectionMaturityBadge(connection: connection)
                                Spacer()
                                Button { editing = connection } label: {
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Edit \(connection.name)")
                                Button { removing = connection } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Remove \(connection.name) from this \(member)")
                            }.padding(8)
                        }
                        // A connection deleted since it was granted.
                        ForEach(selectedIDs.subtracting(known).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            HStack {
                                Label("Unavailable Tool", systemImage: "exclamationmark.triangle")
                                Spacer()
                                Button { selectedIDs.remove(id) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Remove from this \(member)")
                            }.padding(8)
                        }
                        extraRows()
                    }
                }.frame(height: Self.listHeight)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .sheet(isPresented: $showingNewTool) {
            ToolCreationSheet(controller: controller, onAdded: { selectedIDs.insert($0) }).noodleSheetSizing()
        }
        .sheet(item: $editing) { connection in
            ToolConnectionEditor(controller: controller, existing: connection).noodleSheetSizing()
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { connection in
            Button("Remove Tool", role: .destructive) { selectedIDs.remove(connection.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This \(member) loses access to it when you save. The tool connection itself is not deleted.")
        }
    }

    private var chooser: some View {
        ToolConnectionChooser(controller: controller, selectedIDs: $selectedIDs, search: $search,
                              extras: chooserExtras) { wantsNewTool = true; showingAdd = false }
    }
}

/// Adds saved connections, found by name; the app's own tools come first, given the search.
struct ToolConnectionChooser<Extras: View>: View {
    let controller: ToolConnectionsController
    @Binding var selectedIDs: Set<UUID>
    @Binding var search: String
    @ViewBuilder var extras: (String) -> Extras
    let onNewTool: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            ScrollView {
                LazyVStack(spacing: 4) {
                    extras(search)
                    ForEach(controller.registry.connections.filter {
                        !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                    }) { connection in
                        Button { selectedIDs.insert(connection.id) } label: {
                            HStack(spacing: 10) {
                                ToolConnectionIcon(connection: connection, size: 28)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(connection.name).foregroundStyle(Color.primary)
                                        ToolConnectionMaturityBadge(connection: connection)
                                    }
                                    Text(connection.description).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if controller.registry.connections.isEmpty {
                        Text("No saved connections. Choose New to add one.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack {
                Button(action: onNewTool) { Label("New", systemImage: "plus") }.help("New Tool").accessibilityLabel("New Tool")
                Spacer()
            }
        }.padding(16).frame(width: 330, height: 260)
    }
}

extension ToolAssignmentList where Rows == EmptyView, Extras == EmptyView {
    /// Saved connections only.
    init(controller: ToolConnectionsController, selectedIDs: Binding<Set<UUID>>, member: String) {
        self.init(controller: controller, selectedIDs: selectedIDs, member: member, extraRows: { EmptyView() }, chooserExtras: { _ in EmptyView() })
    }
}
