import SwiftUI
import NoodleCore

public struct MCPSettingsView: View {
    let store: any BotSettingsHost
    @State private var showingAdd = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    @State private var connectionsHeight: CGFloat = 80
    public var body: some View {
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

    public init(store: any BotSettingsHost) {
        self.store = store
    }
}

public struct MCPEditor: View {
    /// Saves the connection wherever it is kept and returns it as saved.
    private let saveRecord: (MCPConnectionRecord) async throws -> MCPConnectionRecord
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
    @State private var saving = false
    public init(controller: MCPController, existing: MCPConnectionRecord? = nil,
         onBack: (() -> Void)? = nil, onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
         onConnect: ((MCPConnectionRecord) -> Void)? = nil) {
        self.init(existing: existing, onBack: onBack, onSaved: onSaved, onConnect: onConnect ?? controller.connect) { record in
            try controller.save(record)
            return controller.registry.connections.first { $0.id == record.id } ?? record
        }
    }

    /// For a connection kept somewhere other than this Mac, as on a Noodle Hub.
    public init(existing: MCPConnectionRecord? = nil, onBack: (() -> Void)? = nil,
                onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
                onConnect: @escaping (MCPConnectionRecord) -> Void,
                save: @escaping (MCPConnectionRecord) async throws -> MCPConnectionRecord) {
        self.saveRecord = save; self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
    }
    public var body: some View {
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
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.isEmpty || saving)
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
        saving = true
        Task { @MainActor in
            await submit()
            saving = false
        }
    }
    private func submit() async {
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
            record = try await saveRecord(record)
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

public struct MCPConnectionIcon: View {
    let connection: MCPConnectionRecord
    let size: CGFloat
    public var body: some View {
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

    public init(connection: MCPConnectionRecord, size: CGFloat) {
        self.connection = connection
        self.size = size
    }
}
