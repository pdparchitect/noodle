import AppKit
import SwiftUI
import NoodleCore

public struct MCPSettingsView: View {
    let store: any BotSettingsHost
    /// Tools the app has built in, listed above the connections and never removed.
    private let builtIn: AnyView?
    @State private var showingAdd = false
    @State private var editing: MCPConnectionRecord?
    @State private var removing: MCPConnectionRecord?
    @State private var connectionsHeight: CGFloat = 80
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let builtIn {
                        builtIn
                        if !store.mcp.registry.all.isEmpty { Divider().padding(.leading, 58) }
                    }
                    if store.mcp.registry.all.isEmpty && builtIn == nil {
                        Label("No connections", systemImage: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(store.mcp.registry.all) { connection in
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
                                    Button("Edit…") { editing = connection }
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
                        if connection.id != store.mcp.registry.all.last?.id { Divider().padding(.leading, 58) }
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
        builtIn = nil
    }

    public init(store: any BotSettingsHost, @ViewBuilder builtIn: () -> some View) {
        self.store = store
        self.builtIn = AnyView(builtIn())
    }
}

public struct MCPEditor: View {
    /// Saves the connection on this Mac at once, or elsewhere, as on a Noodle Hub, and returns it as saved.
    private let saveNow: ((MCPConnectionRecord) throws -> MCPConnectionRecord)?
    private let saveLater: ((MCPConnectionRecord) async throws -> MCPConnectionRecord)?
    private let storeBearer: ((String, MCPConnectionRecord) async throws -> Void)?
    private let discardBearer: ((MCPConnectionRecord) async throws -> Void)?
    /// The Mac app can add a server on this Mac. Noodle Hub only adds a remote server.
    private let choosesPlace: Bool
    let existing: MCPConnectionRecord?
    let onBack: (() -> Void)?
    let onSaved: (MCPConnectionRecord) -> Void
    private let onConnect: (MCPConnectionRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var description: String
    @State private var instructions: String
    @State private var place: MCPConnectionPlace
    @State private var authorization: MCPLocalAuthorization
    @State private var bearer: String
    @State private var allowed: Bool
    @State private var error: String?
    @State private var newConnectionID = UUID()
    @State private var saving = false
    public init(controller: MCPController, existing: MCPConnectionRecord? = nil,
         onBack: (() -> Void)? = nil, onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
         onConnect: ((MCPConnectionRecord) -> Void)? = nil) {
        saveNow = { record in
            try controller.save(record)
            return controller.registry.record(record.id) ?? record
        }
        saveLater = nil
        storeBearer = { token, record in try await controller.storeBearer(token, for: record) }
        discardBearer = { record in try await controller.discardLoopbackBearer(record) }
        choosesPlace = true
        self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect ?? controller.connect
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
        _place = State(initialValue: existing?.place ?? .remote)
        _authorization = State(initialValue: Self.shownAuthorization(existing?.authorization))
        _bearer = State(initialValue: "")
        _allowed = State(initialValue: existing?.consentedOrigin != nil)
    }

    /// For a connection kept somewhere other than this Mac, as on a Noodle Hub.
    public init(existing: MCPConnectionRecord? = nil, onBack: (() -> Void)? = nil,
                onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
                onConnect: @escaping (MCPConnectionRecord) -> Void,
                save: @escaping (MCPConnectionRecord) async throws -> MCPConnectionRecord) {
        saveNow = nil
        saveLater = save
        storeBearer = nil
        discardBearer = nil
        choosesPlace = false
        self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
        _place = State(initialValue: existing?.place ?? .remote)
        _authorization = State(initialValue: Self.shownAuthorization(existing?.authorization))
        _bearer = State(initialValue: "")
        _allowed = State(initialValue: existing?.consentedOrigin != nil)
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
                if choosesPlace, existing == nil {
                    Picker("Connection", selection: $place) {
                        Text("Remote server").tag(MCPConnectionPlace.remote)
                        Text("Server on this Mac").tag(MCPConnectionPlace.loopback)
                    }.pickerStyle(.radioGroup)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(place == .loopback ? "Address on this Mac" : "MCP Server URL").font(.caption.weight(.semibold))
                    TextField(place == .loopback ? "http://127.0.0.1:8080/mcp" : "https://…", text: $endpoint, axis: .horizontal).lineLimit(1)
                        .autocorrectionDisabled().disabled(existing != nil)
                }
                if place == .loopback {
                    Picker("Authorization", selection: $authorization) {
                        Text("No token").tag(MCPLocalAuthorization.none)
                        Text("Bearer token").tag(MCPLocalAuthorization.bearer)
                    }.pickerStyle(.radioGroup)
                    if authorization == .bearer {
                        SecureField("Bearer token", text: $bearer)
                            .help("Stored in the login keychain. It is not written into the address or the registry.")
                    }
                    Toggle(isOn: $allowed) {
                        Text(consentText)
                    }
                    .font(.caption)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.caption.weight(.semibold))
                    TextField("Optional", text: $description, axis: .vertical).lineLimit(2...3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions").font(.caption.weight(.semibold))
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .roundedBorderEditor()
                        .frame(height: 130)
                        .help("Optional guidance for bots using this connection. Do not include passwords or tokens.")
                }
                Text(place == .loopback
                     ? "A server on this Mac receives tool calls from the agents you assign. A program on this Mac is not started by Noodle."
                     : "MCP connection · Sign-in opens in your browser.")
                    .font(.caption).foregroundStyle(.secondary)
                if existing != nil {
                    Text("Changes apply to every bot using this connection.").font(.caption).foregroundStyle(.secondary)
                }
                if onBack != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(20)
        }.frame(width: 480)
    }
    private static func shownAuthorization(_ stored: MCPLocalAuthorization?) -> MCPLocalAuthorization {
        guard let stored, stored != .browser else { return MCPLocalAuthorization.none }
        return stored
    }
    private var consentText: String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = URL(string: trimmed).map { MCPConnectionRecord.origin(of: $0) } ?? trimmed
        let host = origin.split(separator: "://").last.map(String.init) ?? origin
        return "Noodle on this Mac will send tool calls from the agents you assign to the program listening on \(host). Any program that listens on that port will receive them."
    }
    private func save() {
        do {
            let record = try draft()
            let trimmedBearer = bearer.trimmingCharacters(in: .whitespacesAndNewlines)
            if place == .loopback, authorization == .bearer, trimmedBearer.isEmpty, existing?.authorization != .bearer {
                throw MCPConnectionError.message("Enter the bearer token in the secure field.")
            }
            // An empty field on an existing bearer connection leaves the saved token in place.
            let token = (place == .loopback && authorization == .bearer && !trimmedBearer.isEmpty) ? trimmedBearer : nil
            if let token, storeBearer == nil {
                throw MCPConnectionError.message("Save the bearer token in Noodle on this Mac.")
            }
            let dropBearer = place == .loopback && authorization != .bearer
            if let saveNow {
                let saved = try saveNow(record)
                if (token != nil && storeBearer != nil) || (dropBearer && discardBearer != nil) {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            if let token, let storeBearer { try await storeBearer(token, saved) }
                            if dropBearer, let discardBearer { try await discardBearer(saved) }
                            finish(saved)
                        } catch { self.error = error.localizedDescription }
                    }
                    return
                }
                return finish(saved)
            }
            saving = true
            Task { @MainActor in
                defer { saving = false }
                do { finish(try await saveLater!(record)) } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func draft() throws -> MCPConnectionRecord {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPConnectionError.message(place == .loopback
                ? "Enter a loopback HTTP address without credentials or a fragment."
                : "Enter a valid HTTPS server URL.")
        }
        // A registry save can succeed before workspace refresh fails. Keep
        // the draft's identity so retry updates that account in place.
        let record: MCPConnectionRecord
        if place == .loopback {
            let origin = MCPConnectionRecord.origin(of: try MCPConnectionRecord.validatedLoopbackEndpoint(url))
            record = try existing ?? MCPConnectionRecord(id: newConnectionID, name: name, loopback: url,
                authorization: authorization, consentedOrigin: allowed ? origin : nil)
        } else {
            record = try existing ?? MCPConnectionRecord(id: newConnectionID, name: name, endpoint: url)
        }
        var editable = record
        editable.name = try ConversationName.validated(name)
        editable.description = String(description.prefix(1_000))
        editable.instructions = String(instructions.prefix(20_000))
        if place == .loopback {
            editable.authorization = authorization
            editable.consentedOrigin = allowed ? MCPConnectionRecord.origin(of: record.endpoint) : nil
        }
        return editable
    }
    private func finish(_ record: MCPConnectionRecord) {
        onSaved(record)
        let shouldConnect = existing == nil && (record.place != .loopback || record.consentedOrigin != nil)
        dismiss()
        if shouldConnect {
            Task { @MainActor in
                // Present authorization after the editor sheet has dismissed.
                try? await Task.sleep(for: .milliseconds(250))
                onConnect(record)
            }
        }
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

public extension View {
    /// Puts a TextEditor inside a real `.roundedBorder` field bezel, so
    /// multi-line fields match the single-line ones beside them. The bezel is
    /// translucent and its colours depend on where it sits, so it is drawn by
    /// AppKit rather than imitated.
    func roundedBorderEditor() -> some View {
        scrollContentBackground(.hidden)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .background { RoundedBorderBezel() }
    }
}

private struct RoundedBorderBezel: NSViewRepresentable {
    final class BezelView: NSView {
        private let field = NSTextField(string: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            field.isEditable = false
            field.isSelectable = false
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.refusesFirstResponder = true
            field.setAccessibilityElement(false)
            addSubview(field)
        }

        required init?(coder: NSCoder) { nil }

        // The field keeps its one-line intrinsic height under constraints or
        // autoresizing; setting its frame here lets the bezel fill the editor.
        override func layout() {
            super.layout()
            field.frame = bounds
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> BezelView { BezelView() }
    func updateNSView(_ nsView: BezelView, context: Context) {}
}
