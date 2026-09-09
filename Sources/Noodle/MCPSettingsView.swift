import SwiftUI
import NoodleCore

struct MCPSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var showingAdd = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    var body: some View {
        VStack(spacing: 12) {
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
                                Text(connection.name).font(.headline)
                                Text(connection.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !connection.description.isEmpty {
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if store.mcp.signingIn == connection.id {
                                    Text(store.mcp.signInStage).font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = store.mcp.errors[connection.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack {
                                    Button(store.mcp.connected.contains(connection.id) ? "Reconnect…" : "Connect…") { store.mcp.connect(connection) }
                                        .disabled(store.mcp.signingIn != nil)
                                    Button("Edit…") { editing = connection }
                                    Button("Remove…") { removing = connection }
                                }.controlSize(.small).padding(.top, 3)
                            }
                            Spacer(minLength: 4)
                            if store.mcp.signingIn == connection.id {
                                VStack { ProgressView().controlSize(.small); Button("Cancel") { store.mcp.cancelSignIn() }.controlSize(.small) }
                            } else {
                                Image(systemName: store.mcp.errors[connection.id] != nil ? "exclamationmark.triangle" :
                                    store.mcp.connected.contains(connection.id) ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                                    .foregroundStyle(store.mcp.errors[connection.id] != nil ? .orange :
                                        store.mcp.connected.contains(connection.id) ? .green : .secondary)
                                    .help(store.mcp.connected.contains(connection.id) ? "Connected" : "Sign-in required")
                            }
                        }.padding(14)
                        if connection.id != store.mcp.registry.connections.last?.id { Divider().padding(.leading, 58) }
                    }
                }
            }
            .frame(height: min(430, max(80, CGFloat(store.mcp.registry.connections.count) * 130)))
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Spacer()
                Button { showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .help("Add a service or another account")
            }
        }
        .padding(20)
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
}

struct MCPEditor: View {
    let controller: MCPController
    let existing: MCPConnectionRecord?
    let onBack: (() -> Void)?
    let onSaved: (MCPConnectionRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var description: String
    @State private var instructions: String
    @State private var error: String?
    init(controller: MCPController, existing: MCPConnectionRecord? = nil,
         onBack: (() -> Void)? = nil, onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in }) {
        self.controller = controller; self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
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
                Text("MCP connection · Sign-in opens in your browser. Requires automatic client registration; API keys are not supported.")
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
            var record = try existing ?? MCPConnectionRecord(name: name, endpoint: url)
            record.name = try ConversationName.validated(name)
            record.description = String(description.prefix(1_000))
            record.instructions = String(instructions.prefix(20_000))
            try controller.save(record)
            onSaved(record)
            let shouldConnect = existing == nil
            dismiss()
            if shouldConnect {
                Task { @MainActor in
                    // Present authorization after the editor sheet has dismissed.
                    try? await Task.sleep(for: .milliseconds(250))
                    controller.connect(record)
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
    @State private var showingAdd = false
    @State private var search = ""
    @State private var wantsNewTool = false
    @State private var showingNewTool = false
    @State private var editing: MCPConnectionRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tool Connections").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                        VStack(spacing: 10) {
                            TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(controller.registry.connections.filter {
                                        !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                                    }) { connection in
                                        Button { selectedIDs.insert(connection.id) } label: {
                                            HStack(spacing: 10) {
                                                MCPConnectionIcon(connection: connection, size: 28)
                                                VStack(alignment: .leading) {
                                                    Text(connection.name).foregroundStyle(.primary)
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
                                Button("New Tool…") { wantsNewTool = true; showingAdd = false }
                                Spacer()
                                Button("Done") { showingAdd = false }
                            }
                        }.padding(16).frame(width: 330, height: 260)
                            .onDisappear {
                                // Wait for the popover to close before presenting a sheet
                                // on the bot editor. No nested popover or global window.
                                if wantsNewTool { wantsNewTool = false; showingNewTool = true }
                            }
                    }
            }
            if selectedIDs.isEmpty {
                Text("No tool connections assigned").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(controller.registry.connections.filter { selectedIDs.contains($0.id) }) { connection in
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 26)
                                Text(connection.name).lineLimit(1)
                                Spacer()
                                Button { editing = connection } label: {
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Edit \(connection.name)")
                                Button { selectedIDs.remove(connection.id) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).help("Remove \(connection.name) from this bot")
                            }.padding(8)
                        }
                    }
                }.frame(height: min(156, CGFloat(selectedIDs.count) * 44))
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                Text("This bot can use these accounts' tools within the permissions you granted at sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingNewTool) {
            ToolCreationSheet(controller: controller, onAdded: { selectedIDs.insert($0) }).noodleSheetSizing()
        }
        .sheet(item: $editing) { connection in
            MCPEditor(controller: controller, existing: connection).noodleSheetSizing()
        }
    }
}
