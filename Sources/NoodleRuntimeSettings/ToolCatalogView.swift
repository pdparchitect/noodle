import AppKit
import SwiftUI
import NoodleCore

/// Protocol-independent catalogue. Setup routing is kept in ToolCreationSheet.
public struct ToolCatalogView: View {
    let onSelect: (ToolDefinition) -> Void
    let onCustomMCP: () -> Void
    let onCancel: () -> Void
    var error: String? = nil
    /// Whether services set up with a form (an API key, or details such as a domain) are listed; not where
    /// those cannot be kept yet, as on a Noodle Hub.
    var includesSetUpTools = true
    @State private var search = ""

    private var tools: [ToolDefinition] {
        ToolCatalog.matching(search).filter { tool in
            includesSetUpTools || !tool.needsSetUp
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Text("New Tool").font(.headline)
                Spacer()
                // Balance the title without adding another focusable control.
                Text("Cancel").hidden().accessibilityHidden(true)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search tools", text: $search)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Text("Choose a service to add it and sign in. You can customize it afterward.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tools) { tool in
                            Button { onSelect(tool) } label: {
                                HStack(spacing: 12) {
                                    ToolCatalogIcon(tool: tool, size: 32)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.name).foregroundStyle(.primary)
                                        Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    ToolMaturityBadge(maturity: tool.maturity)
                                    Text(tool.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }.padding(9).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(tool.needsSetUp ? "Set up \(tool.name)" : "Add \(tool.name) and sign in")
                        }
                        if tools.isEmpty {
                            Text("No matching tools. You can add a custom MCP below.")
                                .font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                }.frame(height: 310)
                Divider()
                HStack {
                    Button("Custom MCP…", action: onCustomMCP)
                    Spacer()
                    Text("Connect your own MCP server")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }.frame(width: 480)
    }
}

public struct ToolMaturityBadge: View {
    let maturity: ToolMaturity
    public var body: some View {
        if let badge = maturity.badge {
            Text(badge).font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.12), in: Capsule())
        }
    }
}

public struct MCPConnectionMaturityBadge: View {
    let connection: MCPConnectionRecord
    public var body: some View {
        if let tool = ToolCatalog.definition(for: connection) {
            ToolMaturityBadge(maturity: tool.maturity)
        }
    }

    public init(connection: MCPConnectionRecord) {
        self.connection = connection
    }
}

/// One dispatch boundary per supported tool type; MCP owns its form and storage.
public struct ToolCreationSheet: View {
    var onAdded: (UUID) -> Void = { _ in }
    private let onConnect: (MCPConnectionRecord) -> Void
    /// On this Mac, adding is immediate; elsewhere, as on a Noodle Hub, it waits for an answer.
    private let controller: MCPController?
    private let addPreset: ((ToolDefinition, MCPToolConfiguration, UUID) async throws -> MCPConnectionRecord)?
    private let save: ((MCPConnectionRecord) async throws -> MCPConnectionRecord)?
    @Environment(\.dismiss) private var dismiss
    @State private var customMCP = false
    @State private var error: String?
    @State private var adding = false
    @State private var presetAttempts: [String: UUID] = [:]
    /// A preset whose form is open: one that takes an API key or details such as a domain.
    @State private var settingUp: ToolDefinition?

    public init(controller: MCPController, onAdded: @escaping (UUID) -> Void = { _ in },
         onConnect: ((MCPConnectionRecord) -> Void)? = nil) {
        self.controller = controller; self.onAdded = onAdded; self.onConnect = onConnect ?? { controller.connect($0) }
        addPreset = nil; save = nil
    }

    /// For connections kept somewhere other than this Mac, as on a Noodle Hub.
    public init(onAdded: @escaping (UUID) -> Void = { _ in }, onConnect: @escaping (MCPConnectionRecord) -> Void,
                addPreset: @escaping (ToolDefinition, MCPToolConfiguration, UUID) async throws -> MCPConnectionRecord,
                save: @escaping (MCPConnectionRecord) async throws -> MCPConnectionRecord) {
        controller = nil; self.onAdded = onAdded; self.onConnect = onConnect; self.addPreset = addPreset; self.save = save
    }

    public var body: some View {
        Group {
            if let tool = settingUp, let controller, case .mcp(let configuration) = tool.configuration {
                PresetSetUpForm(tool: tool, configuration: configuration,
                                name: ToolCatalog.availableName(for: tool, existingNames: controller.registry.connections.map(\.name)),
                                onBack: { settingUp = nil; error = nil }) { name, values, secret in
                    // Each one is a new account, whatever others share with it.
                    let connection = try controller.addPreset(tool, configuration: configuration, name: name, values: values)
                    onAdded(connection.id)
                    dismiss()
                    if let secret { controller.connect(connection, secret: secret) } else { onConnect(connection) }
                }
            } else if customMCP, let controller {
                MCPEditor(controller: controller, onBack: { customMCP = false }, onSaved: { onAdded($0.id) }, onConnect: onConnect)
            } else if customMCP, let save {
                MCPEditor(onBack: { customMCP = false }, onSaved: { onAdded($0.id) }, onConnect: onConnect, save: save)
            } else {
                ToolCatalogView(onSelect: add, onCustomMCP: { customMCP = true },
                                onCancel: { dismiss() }, error: error, includesSetUpTools: controller != nil).disabled(adding)
            }
        }
    }

    private func add(_ tool: ToolDefinition) {
        guard !adding, case .mcp(let configuration) = tool.configuration else { return }
        if tool.needsSetUp, controller != nil { settingUp = tool; return }
        adding = true
        // Saving the account can precede a failed workspace refresh.
        // Retrying this preset must resume that account, even after
        // the user has tried another preset in the same sheet.
        let id = presetAttempts[tool.id] ?? UUID()
        presetAttempts[tool.id] = id
        if let controller {
            do { added(try controller.addPreset(tool, configuration: configuration, connectionID: id)) }
            catch { self.error = error.localizedDescription; adding = false }
            return
        }
        Task { @MainActor in
            do { added(try await addPreset!(tool, configuration, id)) }
            catch { self.error = error.localizedDescription; adding = false }
        }
    }

    private func added(_ connection: MCPConnectionRecord) {
        onAdded(connection.id)
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            onConnect(connection)
        }
    }
}

/// What a preset needs before its account can be added: a name, its fields, such as a domain, and its API key
/// when it takes one. Every account is set up from scratch.
private struct PresetSetUpForm: View {
    let tool: ToolDefinition
    let configuration: MCPToolConfiguration
    let onBack: () -> Void
    let onAdd: (String, [String: String], MCPConnectionSecret?) throws -> Void
    @State private var name: String
    @State private var values: [String: String] = [:]
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?

    init(tool: ToolDefinition, configuration: MCPToolConfiguration, name: String, onBack: @escaping () -> Void,
         onAdd: @escaping (String, [String: String], MCPConnectionSecret?) throws -> Void) {
        self.tool = tool; self.configuration = configuration; self.onBack = onBack; self.onAdd = onAdd
        _name = State(initialValue: name)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: configuration.fields.compactMap { field in
            if case .choice(let options) = field.kind, let first = options.first { return (field.key, first.value) }
            return nil
        }))
    }

    private var complete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && configuration.fields.allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (configuration.tokenHeader == nil || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (configuration.clientCredentials == nil || ![clientID, clientSecret].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var secret: MCPConnectionSecret? {
        if configuration.tokenHeader != nil { return .token(token) }
        if configuration.clientCredentials != nil { return .client(id: clientID, secret: clientSecret) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", action: onBack).keyboardShortcut(.cancelAction)
                Spacer()
                Text(tool.name).font(.headline)
                Spacer()
                Button("Add & Connect") {
                    do { try onAdd(name, values, secret) } catch { self.error = error.localizedDescription }
                }
                .disabled(!complete)
                .keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ToolCatalogIcon(tool: tool, size: 32)
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                }
                field("Name") {
                    TextField("e.g. \(tool.name) — Work", text: $name, axis: .horizontal).lineLimit(1)
                }
                ForEach(configuration.fields, id: \.key) { item in
                    field(item.title) {
                        let value = Binding(get: { values[item.key] ?? "" }, set: { values[item.key] = $0 })
                        switch item.kind {
                        case .choice(let options):
                            Picker(item.title, selection: value) {
                                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .labelsHidden()
                        case .host, .text:
                            TextField(item.placeholder, text: value, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                    }
                }
                if configuration.tokenHeader != nil {
                    field("API Key") { SecureField("Paste the key", text: $token) }
                }
                if configuration.clientCredentials != nil {
                    field("Client ID") { TextField("Client ID", text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled() }
                    field("Client Secret") { SecureField("Client secret", text: $clientSecret) }
                }
                if secret != nil {
                    Text("Kept in Keychain and used for every request.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(20)
        }.frame(width: 480)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            content()
        }
    }
}

public struct ToolCatalogIcon: View {
    let tool: ToolDefinition
    let size: CGFloat

    static func image(for tool: ToolDefinition) -> NSImage? {
        guard let url = Bundle.main.url(forResource: tool.iconName, withExtension: "icon", subdirectory: "ToolIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    public var body: some View {
        Group {
            if let image = Self.image(for: tool) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(String(tool.name.prefix(1))).font(.system(size: size * 0.55, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}
