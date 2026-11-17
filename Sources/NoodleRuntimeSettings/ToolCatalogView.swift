import AppKit
import SwiftUI
import NoodleCore
import ProductIdentity

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
            includesSetUpTools || !tool.staysOnThisMac
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel).buttonStyle(.sheetHeader).keyboardShortcut(.cancelAction)
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
                                    Text(tool.kind.rawValue)
                                        .font(.caption2).foregroundStyle(.secondary)
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

public struct ToolConnectionMaturityBadge: View {
    let connection: ToolConnection
    public var body: some View {
        if let tool = ToolCatalog.definition(for: connection) {
            ToolMaturityBadge(maturity: tool.maturity)
        }
    }

    public init(connection: ToolConnection) {
        self.connection = connection
    }
}

/// One dispatch boundary per supported tool type; MCP owns its form and storage.
public struct ToolCreationSheet: View {
    var onAdded: (UUID) -> Void = { _ in }
    private let onConnect: (ToolConnection) -> Void
    /// On this Mac, adding is immediate; elsewhere, as on a Noodle Hub, it waits for an answer.
    private let controller: ToolConnectionsController?
    private let addPreset: ((ToolDefinition, ToolConnectionConfiguration, UUID) async throws -> ToolConnection)?
    private let save: ((ToolConnection) async throws -> ToolConnection)?
    @Environment(\.dismiss) private var dismiss
    @State private var customMCP = false
    @State private var error: String?
    @State private var adding = false
    @State private var presetAttempts: [String: UUID] = [:]
    /// A preset whose form is open: one that takes an API key or details such as a domain.
    @State private var settingUp: ToolDefinition?

    public init(controller: ToolConnectionsController, onAdded: @escaping (UUID) -> Void = { _ in },
         onConnect: ((ToolConnection) -> Void)? = nil) {
        self.controller = controller; self.onAdded = onAdded; self.onConnect = onConnect ?? { controller.connect($0) }
        addPreset = nil; save = nil
    }

    /// For connections kept somewhere other than this Mac, as on a Noodle Hub.
    public init(onAdded: @escaping (UUID) -> Void = { _ in }, onConnect: @escaping (ToolConnection) -> Void,
                addPreset: @escaping (ToolDefinition, ToolConnectionConfiguration, UUID) async throws -> ToolConnection,
                save: @escaping (ToolConnection) async throws -> ToolConnection) {
        controller = nil; self.onAdded = onAdded; self.onConnect = onConnect; self.addPreset = addPreset; self.save = save
    }

    public var body: some View {
        Group {
            if let tool = settingUp, let controller, case .connection(let configuration) = tool.configuration {
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
                ToolConnectionEditor(controller: controller, onBack: { customMCP = false }, onSaved: { onAdded($0.id) }, onConnect: onConnect)
            } else if customMCP, let save {
                ToolConnectionEditor(onBack: { customMCP = false }, onSaved: { onAdded($0.id) }, onConnect: onConnect, save: save)
            } else {
                ToolCatalogView(onSelect: add, onCustomMCP: { customMCP = true },
                                onCancel: { dismiss() }, error: error, includesSetUpTools: controller != nil).disabled(adding)
            }
        }
    }

    private func add(_ tool: ToolDefinition) {
        guard !adding, case .connection(let configuration) = tool.configuration else { return }
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

    private func added(_ connection: ToolConnection) {
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
    let configuration: ToolConnectionConfiguration
    let onBack: () -> Void
    let onAdd: (String, [String: String], ToolConnectionSecret?) throws -> Void
    @State private var name: String
    @State private var values: [String: String] = [:]
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var sessionToken = ""
    @State private var serviceAccountKey = ""
    @State private var error: String?

    init(tool: ToolDefinition, configuration: ToolConnectionConfiguration, name: String, onBack: @escaping () -> Void,
         onAdd: @escaping (String, [String: String], ToolConnectionSecret?) throws -> Void) {
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
            && (!configuration.usesToken || configuration.composedToken != nil || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (configuration.composedToken == nil || ![clientID, clientSecret].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            && (configuration.googleScopes == nil || !serviceAccountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (configuration.clientCredentials == nil && !configuration.signsForAWS
                || ![clientID, clientSecret].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var secret: ToolConnectionSecret? {
        if let composed = configuration.composedToken { return (try? composed.compose(clientID, clientSecret)).map { .token($0) } }
        if configuration.usesToken { return .token(token) }
        if configuration.clientCredentials != nil { return .client(id: clientID, secret: clientSecret) }
        if configuration.signsForAWS { return .aws(accessKeyID: clientID, secretAccessKey: clientSecret, sessionToken: sessionToken) }
        if configuration.googleScopes != nil { return .google(serviceAccountKey) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", action: onBack).buttonStyle(.sheetHeader).keyboardShortcut(.cancelAction)
                Spacer()
                Text(tool.name).font(.headline)
                Spacer()
                Button("Add & Connect") {
                    do {
                        // A composed token's values are checked here, so a bad one is said before anything is added.
                        if let composed = configuration.composedToken { _ = try composed.compose(clientID, clientSecret) }
                        try onAdd(name, values, secret)
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.sheetHeader)
                .disabled(!complete)
                .keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ToolCatalogIcon(tool: tool, size: 32)
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                }
                if !tool.setup.isEmpty { ToolSetupSteps(steps: tool.setup) }
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
                        case .host, .text, .identifier, .address:
                            TextField(item.placeholder, text: value, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                    }
                }
                if let composed = configuration.composedToken {
                    field(composed.first) { TextField(composed.first, text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled() }
                    field(composed.second) { SecureField(composed.second, text: $clientSecret) }
                } else if configuration.usesToken {
                    field("API Key") { SecureField("Paste the key", text: $token) }
                }
                if configuration.googleScopes != nil {
                    field("Service Account Key") { ServiceAccountKeyField(key: $serviceAccountKey) }
                }
                if configuration.signsForAWS {
                    field("Access Key ID") { TextField("AKIA…", text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled() }
                    field("Secret Access Key") { SecureField("Secret access key", text: $clientSecret) }
                    field("Session Token") { SecureField("Only for temporary credentials", text: $sessionToken) }
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

/// A preset's steps for getting the key or account it asks for, folded until opened. They stay in the form, so
/// they can be followed in the service's console while it is filled in.
struct ToolSetupSteps: View {
    let steps: [String]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Setup Steps", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        Text(Self.markdown(step)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .padding(.top, 6)
        }
    }

    static func markdown(_ step: String) -> AttributedString {
        (try? AttributedString(markdown: step, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(step)
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
