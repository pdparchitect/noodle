import AppKit
import SwiftUI
import NoodleCore

public struct MCPSettingsView: View {
    let store: any BotSettingsHost
    /// Tools the app has built in, listed above the connections and never removed.
    private let builtIn: AnyView?
    @State private var showingAdd = false
    @State private var showingProgram = false
    @State private var editing: MCPConnectionRecord?
    @State private var editingProgram: MCPProgramRecord?
    @State private var removing: MCPConnectionRecord?
    @State private var removingProgram: MCPProgramRecord?
    @State private var connectionsHeight: CGFloat = 80
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let builtIn {
                        builtIn
                        if !store.mcp.registry.connections.isEmpty { Divider().padding(.leading, 58) }
                    }
                    if store.mcp.registry.connections.isEmpty && builtIn == nil {
                        Label("No connections", systemImage: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(store.mcp.registry.programs) { program in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "terminal").frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(program.name).font(.headline).lineLimit(1)
                                Text(program.executable).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(program.consentedSubject == nil ? "Not approved" : "Approved").font(.caption).foregroundStyle(.secondary)
                                if let error = store.mcp.errors[program.id] {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                                HStack(spacing: 12) {
                                    Button("Edit…") { editingProgram = program }.buttonStyle(.link)
                                    Button("Remove") { removingProgram = program }.buttonStyle(.link)
                                }
                            }
                        }.padding(14)
                        Divider().padding(.leading, 58)
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
                Button { showingProgram = true } label: { Label("Program on this Mac…", systemImage: "terminal") }
                    .help("Start a program on this Mac and talk to it over its standard input and output")
                Button { showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .help("Add a service or another account")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .sheet(isPresented: $showingAdd) { ToolCreationSheet(controller: store.mcp).noodleSheetSizing() }
        .sheet(isPresented: $showingProgram) { MCPProgramEditor(controller: store.mcp, existing: nil).noodleSheetSizing() }
        .sheet(item: $editingProgram) { program in MCPProgramEditor(controller: store.mcp, existing: program).noodleSheetSizing() }
        .confirmationDialog("Remove this program?", isPresented: Binding(get: { removingProgram != nil }, set: { if !$0 { removingProgram = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Program", role: .destructive) {
                if let removingProgram { store.mcp.remove(removingProgram) }
                removingProgram = nil
            }
            Button("Cancel", role: .cancel) { removingProgram = nil }
        }
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
        saveNow = { record in
            try controller.save(record)
            return controller.registry.connections.first { $0.id == record.id } ?? record
        }
        saveLater = nil
        self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect ?? controller.connect
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
    }

    /// For a connection kept somewhere other than this Mac, as on a Noodle Hub.
    public init(existing: MCPConnectionRecord? = nil, onBack: (() -> Void)? = nil,
                onSaved: @escaping (MCPConnectionRecord) -> Void = { _ in },
                onConnect: @escaping (MCPConnectionRecord) -> Void,
                save: @escaping (MCPConnectionRecord) async throws -> MCPConnectionRecord) {
        saveNow = nil
        saveLater = save
        self.existing = existing
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
                        .roundedBorderEditor()
                        .frame(height: 130)
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
            let record = try draft()
            if let saveNow { return finish(try saveNow(record)) }
            saving = true
            Task { @MainActor in
                defer { saving = false }
                do { finish(try await saveLater!(record)) } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func draft() throws -> MCPConnectionRecord {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPConnectionError.message("Enter a valid HTTPS server URL.")
        }
        // A registry save can succeed before workspace refresh fails. Keep
        // the draft's identity so retry updates that account in place.
        var record = try existing ?? MCPConnectionRecord(id: newConnectionID, name: name, endpoint: url)
        record.name = try ConversationName.validated(name)
        record.description = String(description.prefix(1_000))
        record.instructions = String(instructions.prefix(20_000))
        return record
    }
    private func finish(_ record: MCPConnectionRecord) {
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

/// Executable and arguments are separate fields. Nothing is started from this sheet.
public struct MCPProgramEditor: View {
    let controller: MCPController
    let existing: MCPProgramRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var executable: String
    @State private var arguments: String
    @State private var envName: String
    @State private var envValue: String
    @State private var consent: String?
    @State private var error: String?
    @State private var saving = false
    private let id: UUID

    public init(controller: MCPController, existing: MCPProgramRecord?) {
        self.controller = controller
        self.existing = existing
        id = existing?.id ?? UUID()
        _name = State(initialValue: existing?.name ?? "")
        _executable = State(initialValue: existing?.executable ?? "")
        _arguments = State(initialValue: existing?.arguments.joined(separator: "\n") ?? "")
        _envName = State(initialValue: existing?.environmentNames.first ?? "")
        _envValue = State(initialValue: "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Program on this Mac" : "Edit program").font(.headline)
            TextField("Name", text: $name)
            TextField("Executable, such as npx", text: $executable)
            Text("One argument on each line. Do not enter a shell command.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $arguments).font(.system(size: 13)).frame(height: 70)
            TextField("Environment name, such as OPENAPI_MCP_HEADERS", text: $envName)
            SecureField("Environment value. A saved value is not shown again.", text: $envValue)
            Text("A server you already run is a different connection. This does not add one.").font(.caption).foregroundStyle(.secondary)
            if let consent {
                Text(consent).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Don't allow") { Task { await save(allow: false) } }
                    Button("Allow") { Task { await save(allow: true) } }
                        .keyboardShortcut(.defaultAction)
                }.disabled(saving)
            } else {
                Button("Review") { review() }.keyboardShortcut(.defaultAction)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 480)
        .textFieldStyle(.roundedBorder)
    }

    private func argumentList() -> [String] {
        arguments.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    private func review() {
        do {
            let program = try draft(allow: false)
            let resolved = try MCPProgramRecord.resolveExecutable(program.executable, lookup: MCPProgramRecord.pathLookup)
            let directory = MCPProgramRecord.workingDirectory(root: controller.programRoot, id: program.id)
            consent = MCPProgramRecord.consentText(executable: resolved, arguments: program.arguments, workingDirectory: directory,
                                                    user: NSUserName(), mayDownload: MCPProgramRecord.mayDownloadCode(executable: program.executable, arguments: program.arguments))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func draft(allow: Bool) throws -> MCPProgramRecord {
        let names = envName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [envName.trimmingCharacters(in: .whitespacesAndNewlines)]
        var program = try existing ?? MCPProgramRecord(id: id, name: name, executable: executable, arguments: argumentList(), environmentNames: names)
        program.name = try ConversationName.validated(name)
        program.executable = try MCPProgramRecord.validatedExecutable(executable)
        program.arguments = try argumentList().map(MCPProgramRecord.validatedArgument)
        program.environmentNames = try MCPProgramRecord.validatedNames(names)
        if allow {
            let resolved = try MCPProgramRecord.resolveExecutable(program.executable, lookup: MCPProgramRecord.pathLookup)
            let directory = MCPProgramRecord.workingDirectory(root: controller.programRoot, id: program.id)
            program.consentedSubject = MCPProgramRecord.subject(executable: resolved, arguments: program.arguments,
                                                                 workingDirectory: directory, environmentNames: program.environmentNames)
        } else {
            program.consentedSubject = nil
        }
        return program
    }

    private func save(allow: Bool) async {
        saving = true
        defer { saving = false }
        do {
            let program = try draft(allow: allow)
            var secrets: [String: String] = [:]
            if !envName.isEmpty && !envValue.isEmpty { secrets[envName] = envValue }
            try await controller.save(program, secrets: secrets)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
