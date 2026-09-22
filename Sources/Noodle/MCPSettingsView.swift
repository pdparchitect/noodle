import SwiftUI
import NoodleCore

struct MCPSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var showingAdd = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    @State private var connectionsHeight: CGFloat = 80
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if store.mcp.registry.connections.isEmpty {
                        Label("No connections", systemImage: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(store.mcp.registry.connections) { connection in
                        HStack(alignment: .top, spacing: 12) {
                            MCPConnectionIcon(connection: connection, size: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(connection.name).font(.headline).lineLimit(1)
                                    MCPConnectionMaturityBadge(connection: connection)
                                    Spacer(minLength: 4)
                                    connectionStatus(connection)
                                }
                                Text(connection.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !connection.description.isEmpty {
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if let error = store.mcp.errors[connection.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 12) {
                                    Button(store.mcp.connected.contains(connection.id) ? "Reconnect" : "Connect") { store.mcp.connect(connection) }
                                        .buttonStyle(.link)
                                        .disabled(store.mcp.signingIn != nil)
                                    Button("Edit") { editing = connection }
                                        .buttonStyle(.link)
                                    Button("Remove") { removing = connection }
                                        .buttonStyle(.link)
                                    if store.mcp.signingIn == connection.id {
                                        Spacer(minLength: 4)
                                        ProgressView().controlSize(.mini)
                                            .frame(width: 12, height: 12)
                                            .accessibilityLabel("Signing in")
                                        Button("Cancel") { store.mcp.cancelSignIn() }
                                            .controlSize(.small)
                                    }
                                }.padding(.top, 3)
                            }
                        }.padding(14)
                        if connection.id != store.mcp.registry.connections.last?.id { Divider().padding(.leading, 58) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    connectionsHeight = height
                }
            }
            .frame(height: min(430, connectionsHeight))
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button { showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .help("Add a service or another account")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .sheet(isPresented: $showingAdd) { ToolCreationSheet(controller: store.mcp).noodleSheetSizing() }
        .sheet(item: $editing) { connection in MCPEditor(controller: store.mcp, existing: connection).noodleSheetSizing() }
        .confirmationDialog("Remove Tool Connection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Connection", role: .destructive) {
                if let removing { store.mcp.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This removes this connection from all bots and deletes its saved sign-in from Noodle. Other connections to the same service are unchanged. To revoke the provider's grant too, use its account settings.")
        }
        .alert("Tools", isPresented: Binding(get: { store.mcp.errorMessage != nil }, set: { if !$0 { store.mcp.errorMessage = nil } })) {
            Button("OK") { store.mcp.errorMessage = nil }
        } message: { Text(store.mcp.errorMessage ?? "") }
    }

    @ViewBuilder private func connectionStatus(_ connection: MCPConnectionRecord) -> some View {
        if store.mcp.signingIn == connection.id {
            Text(store.mcp.signInStage.isEmpty ? "Signing in…" : store.mcp.signInStage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(store.mcp.signInStage)
        } else if store.mcp.errors[connection.id] != nil {
            SettingsStatusLabel(title: "Needs attention", systemImage: "exclamationmark.triangle", color: .orange)
        } else if store.mcp.connected.contains(connection.id) {
            SettingsStatusLabel(title: "Connected", systemImage: "checkmark.circle.fill", color: .green)
        } else {
            SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
        }
    }
}

struct MCPEditor: View {
    let controller: MCPController
    let existing: MCPConnectionRecord?
    let onBack: (() -> Void)?
    let onSaved: (MCPConnectionRecord) -> Void
    private let onConnect: (MCPConnectionRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var description: String
    @State private var instructions: String
    @State private var error: String?
    @State private var newConnectionID = UUID()
    init(controller: MCPController, existing: MCPConnectionRecord? = nil,
         onBack: (() -> Void)? = nil, onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
         onConnect: ((MCPConnectionRecord) -> Void)? = nil) {
        self.controller = controller; self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect ?? controller.connect
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Text(existing != nil ? "Edit MCP" : "Custom MCP").font(.headline)
                Spacer()
                Button(existing == nil ? "Add & Connect" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption.weight(.semibold))
                    TextField("e.g. Notion — Work", text: $name, axis: .horizontal).lineLimit(1)
                        .help("Use a distinct name for each account")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCP Server URL").font(.caption.weight(.semibold))
                    TextField("https://…", text: $endpoint, axis: .horizontal).lineLimit(1)
                        .autocorrectionDisabled().disabled(existing != nil)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.caption.weight(.semibold))
                    TextField("Optional", text: $description, axis: .vertical).lineLimit(2...3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions").font(.caption.weight(.semibold))
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 130)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)) }
                        .help("Optional guidance for bots using this connection. Do not include passwords or tokens.")
                }
                Text("MCP connection · Sign-in opens in your browser.")
                    .font(.caption).foregroundStyle(.secondary)
                if existing != nil {
                    Text("Changes apply to every bot using this connection.").font(.caption).foregroundStyle(.secondary)
                }
                if onBack != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(20)
        }.frame(width: 480)
    }
    private func save() {
        do {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw MCPConnectionError.message("Enter a valid HTTPS server URL.")
            }
            // A registry save can succeed before workspace refresh fails. Keep
            // the draft's identity so retry updates that account in place.
            var record = try existing ?? MCPConnectionRecord(id: newConnectionID, name: name, endpoint: url)
            record.name = try ConversationName.validated(name)
            record.description = String(description.prefix(1_000))
            record.instructions = String(instructions.prefix(20_000))
            try controller.save(record)
            record = controller.registry.connections.first { $0.id == record.id } ?? record
            onSaved(record)
            let shouldConnect = existing == nil
            dismiss()
            if shouldConnect {
                Task { @MainActor in
                    // Present authorization after the editor sheet has dismissed.
                    try? await Task.sleep(for: .milliseconds(250))
                    onConnect(record)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct MCPConnectionIcon: View {
    let connection: MCPConnectionRecord
    let size: CGFloat
    var body: some View {
        Group {
            if let data = connection.iconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let tool = ToolCatalog.definition(forMCPEndpoint: connection.endpoint) {
                ToolCatalogIcon(tool: tool, size: size)
            } else {
                Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(size * 0.15)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

struct MCPAssignmentPicker: View {
    let controller: MCPController
    @Binding var selectedIDs: Set<UUID>
    /// Noodle's own tools sit in the same list; each carries its own scope.
    let calendars: EventKitController
    let reminders: EventKitController
    @Binding var calendarIDs: Set<String>
    @Binding var reminderIDs: Set<String>
    /// A built-in tool stays in the list while it is on, even before anything is chosen,
    /// so this lives in the sheet: switching tabs rebuilds this view.
    @Binding var builtIn: Set<EventKitAssignments.Kind>
    @State private var showingAdd = false
    @State private var search = ""
    @State private var wantsNewTool = false
    @State private var showingNewTool = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    /// Room for five tools, so the sheet does not jump as they are added or removed.
    private static let listHeight: CGFloat = 5 * 44

    /// On because it is switched on, or because it already has something chosen.
    private var shownBuiltIn: [EventKitAssignments.Kind] {
        EventKitAssignments.Kind.allCases.filter {
            builtIn.contains($0) || !($0 == .calendar ? calendarIDs : reminderIDs).isEmpty
        }
    }
    private var missingBuiltIn: [EventKitAssignments.Kind] {
        EventKitAssignments.Kind.allCases.filter { !shownBuiltIn.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                        MCPConnectionChooser(controller: controller, selectedIDs: $selectedIDs, search: $search,
                            builtIn: $builtIn, missingBuiltIn: missingBuiltIn,
                            onNewTool: { wantsNewTool = true; showingAdd = false }, onDone: { showingAdd = false })
                            .onDisappear {
                                // Wait for the popover to close before presenting a sheet
                                // on the bot editor. No nested popover or global window.
                                if wantsNewTool { wantsNewTool = false; showingNewTool = true }
                            }
                    }
            }
            if selectedIDs.isEmpty && shownBuiltIn.isEmpty {
                Button { search = ""; showingAdd = true } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                        Text("Add tools to this bot")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: Self.listHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Add tools to this bot")
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(controller.registry.connections.filter { selectedIDs.contains($0.id) }) { connection in
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 26)
                                Text(connection.name).lineLimit(1)
                                MCPConnectionMaturityBadge(connection: connection)
                                Spacer()
                                Button { editing = connection } label: {
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Edit \(connection.name)")
                                Button { removing = connection } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Remove \(connection.name) from this bot")
                            }.padding(8)
                        }
                        ForEach(shownBuiltIn, id: \.self) { kind in
                            EventKitToolRow(controller: kind == .calendar ? calendars : reminders,
                                            selectedIDs: kind == .calendar ? $calendarIDs : $reminderIDs,
                                            onRemove: {
                                                builtIn.remove(kind)
                                                if kind == .calendar { calendarIDs = [] } else { reminderIDs = [] }
                                            })
                        }
                    }
                }.frame(height: Self.listHeight)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .sheet(isPresented: $showingNewTool) {
            ToolCreationSheet(controller: controller, onAdded: { selectedIDs.insert($0) }).noodleSheetSizing()
        }
        .sheet(item: $editing) { connection in
            MCPEditor(controller: controller, existing: connection).noodleSheetSizing()
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { connection in
            Button("Remove Tool", role: .destructive) { selectedIDs.remove(connection.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This bot loses access to it when you save. The tool connection itself is not deleted.")
        }
    }
}

struct MCPConnectionChooser: View {
    let controller: MCPController
    @Binding var selectedIDs: Set<UUID>
    @Binding var search: String
    var builtIn: Binding<Set<EventKitAssignments.Kind>>? = nil
    var missingBuiltIn: [EventKitAssignments.Kind] = []
    let onNewTool: () -> Void
    let onDone: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            ScrollView {
                LazyVStack(spacing: 4) {
                    if let builtIn {
                        ForEach(missingBuiltIn.filter {
                            search.isEmpty || $0.toolName.localizedCaseInsensitiveContains(search)
                        }, id: \.self) { kind in
                            Button { builtIn.wrappedValue.insert(kind) } label: {
                                HStack(spacing: 10) {
                                    EventKitToolIcon(symbol: kind == .calendar ? "calendar" : "checklist", size: 28)
                                    VStack(alignment: .leading) {
                                        Text(kind.toolName).foregroundStyle(.primary)
                                        Text("\(kind.noun.capitalized)s on this Mac, chosen per bot")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(controller.registry.connections.filter {
                        !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                    }) { connection in
                        Button { selectedIDs.insert(connection.id) } label: {
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 28)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(connection.name).foregroundStyle(.primary)
                                        MCPConnectionMaturityBadge(connection: connection)
                                    }
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if controller.registry.connections.isEmpty {
                        Text("No saved connections. Choose New Tool to add one.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack {
                Button("New Tool…", action: onNewTool)
                Spacer()
                Button("Done", action: onDone)
            }
        }.padding(16).frame(width: 330, height: 260)
    }
}
