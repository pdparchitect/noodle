import AppKit
import CoreImage
import SwiftUI
import NoodleCore
import NoodleToolConnections
import ProductIdentity

public struct ToolConnectionsSettingsView: View {
    let store: any BotSettingsHost
    /// Tools the app has built in, listed above the connections and never removed.
    private let builtIn: AnyView?
    @State private var showingAdd = false
    @State private var editing: ToolConnection?
    @State private var removing: ToolConnection?
    @State private var connectionsHeight: CGFloat = 80
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let builtIn {
                        builtIn
                        if !store.connectionsController.registry.connections.isEmpty { Divider().padding(.leading, 58) }
                    }
                    if store.connectionsController.registry.connections.isEmpty && builtIn == nil {
                        Label("No connections", systemImage: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(store.connectionsController.registry.connections) { connection in
                        HStack(alignment: .top, spacing: 12) {
                            ToolConnectionIcon(connection: connection, size: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(connection.name).font(.headline).lineLimit(1)
                                    ToolConnectionMaturityBadge(connection: connection)
                                    Spacer(minLength: 4)
                                    connectionStatus(connection)
                                }
                                // A tool the app answers has its entry's address, which says nothing worth a line.
                                if connection.adapter == nil {
                                    Text(connection.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if !connection.description.isEmpty {
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if let error = store.connectionsController.errors[connection.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                                if let note = store.connectionsController.notes[connection.id] {
                                    Text(note.text).font(.caption).foregroundStyle(note.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 12) {
                                    switch store.connectionsController.signInAction(for: connection) {
                                    case .edit(let title):
                                        // A token or client secret is entered in the editor; there is no sign-in to start.
                                        // An AWS Identity Center sign-in is started here, as a browser sign-in is.
                                        Button(title) { editing = connection }
                                            .buttonStyle(.accentLink)
                                            .disabled(store.connectionsController.signingIn != nil || !allows(connection))
                                    case .connect(let title):
                                        Button(title) { store.connectionsController.connect(connection) }
                                            .buttonStyle(.accentLink)
                                            .disabled(store.connectionsController.signingIn != nil || !allows(connection))
                                    case nil:
                                        EmptyView()
                                    }
                                    Button("Edit…") { editing = connection }
                                        .buttonStyle(.accentLink)
                                    Button("Remove") { removing = connection }
                                        .buttonStyle(.accentLink)
                                    if store.connectionsController.signingIn == connection.id {
                                        Spacer(minLength: 4)
                                        ProgressView().controlSize(.mini)
                                            .frame(width: 12, height: 12)
                                            .accessibilityLabel("Signing in")
                                        Button("Cancel") { store.connectionsController.cancelSignIn() }
                                            .controlSize(.small)
                                    }
                                }.padding(.top, 3)
                            }
                        }.padding(14)
                        if connection.id != store.connectionsController.registry.connections.last?.id { Divider().padding(.leading, 58) }
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
                if !OrganisationStatus.shared.allows(.toolConnections) {
                    Text(Organisation.managedText).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .help(OrganisationStatus.shared.allows(.toolConnections) ? "Add a service or another account" : Organisation.managedText)
                    .disabled(!OrganisationStatus.shared.allows(.toolConnections))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .sheet(isPresented: $showingAdd) { ToolCreationSheet(controller: store.connectionsController).noodleSheetSizing() }
        .sheet(item: $editing) { connection in ToolConnectionEditor(controller: store.connectionsController, existing: connection).noodleSheetSizing() }
        .confirmationDialog("Remove Tool Connection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Connection", role: .destructive) {
                if let removing { store.connectionsController.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This removes this connection from everywhere it is assigned, revokes its sign-in or key with the service where the service allows it, and deletes it from \(ProductIdentity.current.name). Where the service doesn't, revoke it in its account settings. Other connections to the same service are unchanged.")
        }
        .alert("Tools", isPresented: Binding(get: { store.connectionsController.errorMessage != nil }, set: { if !$0 { store.connectionsController.errorMessage = nil } })) {
            Button("OK") { store.connectionsController.errorMessage = nil }
        } message: { Text(store.connectionsController.errorMessage ?? "") }
    }

    private func allows(_ connection: ToolConnection) -> Bool {
        OrganisationStatus.shared.allows(Organisation.action(for: connection))
    }

    @ViewBuilder private func connectionStatus(_ connection: ToolConnection) -> some View {
        let status = store.connectionsController.status(of: connection)
        if case .connected = status, store.connectionsController.offersSignOut(connection) {
            ConnectedStatus { store.connectionsController.signOut(connection) }
        } else if case .signingIn(let stage) = status {
            Text(stage.isEmpty ? (ToolConnectionService.signsInThroughBrowser(connection) ? "Signing in…" : "Checking access…") : stage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(stage)
        } else {
            ToolConnectionStatusLabel(status: status)
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

public struct ToolConnectionEditor: View {
    /// Saves the connection on this Mac at once, or elsewhere, as on a Noodle Hub, and returns it as saved.
    private let saveNow: ((ToolConnection) throws -> ToolConnection)?
    private let saveLater: ((ToolConnection) async throws -> ToolConnection)?
    let existing: ToolConnection?
    let onBack: (() -> Void)?
    let onSaved: (ToolConnection) -> Void
    private let onConnect: (ToolConnection) -> Void
    /// Keeps a token or client secret and checks it; nil where those cannot be kept yet, as on a Noodle Hub.
    private let onSecret: ((ToolConnection, ToolConnectionSecret) -> Void)?
    private enum SignIn: Hashable { case browser, token, client }
    @Environment(\.dismiss) private var dismiss
    @State private var signIn: SignIn
    @State private var tokenHeader: String
    @State private var token = ""
    @State private var tokenEndpoint: String
    @State private var scope: String
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var name: String
    @State private var endpoint: String
    @State private var description: String
    @State private var instructions: String
    @State private var error: String?
    @State private var newConnectionID = UUID()
    @State private var saving = false
    /// What the account filled in for its catalogue entry's fields, such as its address and organisation.
    @State private var values: [String: String]
    public init(controller: ToolConnectionsController, existing: ToolConnection? = nil,
         onBack: (() -> Void)? = nil, onSaved: @escaping (ToolConnection) -> Void = { _ in },
         onConnect: ((ToolConnection) -> Void)? = nil) {
        saveNow = { record in
            try controller.save(record)
            return controller.registry.connections.first { $0.id == record.id } ?? record
        }
        saveLater = nil
        self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect ?? { controller.connect($0) }
        onSecret = { controller.connect($0, secret: $1) }
        _signIn = State(initialValue: existing?.usesToken == true ? .token : existing?.clientCredentials != nil ? .client : .browser)
        _values = State(initialValue: existing?.settings ?? [:])
        _tokenHeader = State(initialValue: existing?.tokenHeader ?? "Authorization")
        _tokenEndpoint = State(initialValue: existing?.clientCredentials?.tokenEndpoint.absoluteString ?? "")
        _scope = State(initialValue: existing?.clientCredentials?.scope ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
    }

    /// For a connection kept somewhere other than this Mac, as on a Noodle Hub.
    public init(existing: ToolConnection? = nil, onBack: (() -> Void)? = nil,
                onSaved: @escaping (ToolConnection) -> Void = { _ in },
                onConnect: @escaping (ToolConnection) -> Void,
                save: @escaping (ToolConnection) async throws -> ToolConnection) {
        saveNow = nil
        saveLater = save
        self.existing = existing
        self.onBack = onBack; self.onSaved = onSaved
        self.onConnect = onConnect
        onSecret = nil
        _signIn = State(initialValue: .browser)
        _values = State(initialValue: existing?.settings ?? [:])
        _tokenHeader = State(initialValue: "Authorization")
        _tokenEndpoint = State(initialValue: "")
        _scope = State(initialValue: "")
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button("Back", action: onBack).buttonStyle(.sheetHeader)
                } else {
                    Button("Cancel") { dismiss() }.buttonStyle(.sheetHeader).keyboardShortcut(.cancelAction)
                }
                Spacer()
                Text(existing == nil ? "Custom MCP" : servedByApp ? "Edit Tool" : "Edit MCP").font(.headline)
                Spacer()
                Button(existing == nil ? "Add & Connect" : "Save", action: save)
                    .buttonStyle(.sheetHeader)
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
                // A tool the app answers has the address its entry gives it, which cannot change, so it is not shown.
                if !servedByApp {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MCP Server URL").font(.caption.weight(.semibold))
                        TextField("https://…", text: $endpoint, axis: .horizontal).lineLimit(1)
                            .autocorrectionDisabled().disabled(existing != nil)
                    }
                }
                ForEach(presetFields, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.caption.weight(.semibold))
                        let value = Binding(get: { values[item.key] ?? "" }, set: { values[item.key] = $0 })
                        if case .choice(let options) = item.kind {
                            Picker(item.title, selection: value) {
                                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .labelsHidden()
                        } else {
                            TextField(item.placeholder, text: value, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                    }
                }
                if onSecret != nil {
                    // An adapter connection proves itself the way its adapter expects; only its values change here.
                    if existing?.adapter == nil {
                        Picker("Sign-in", selection: $signIn) {
                            Text("Browser").tag(SignIn.browser)
                            Text("Token").tag(SignIn.token)
                            Text("Client ID & Secret").tag(SignIn.client)
                        }
                        .pickerStyle(.segmented)
                    }
                    if signIn == .client {
                        // A catalogue tool's token address and scope are its entry's.
                        if preset == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Token URL").font(.caption.weight(.semibold))
                                TextField("https://…/oauth2/token", text: $tokenEndpoint, axis: .horizontal).lineLimit(1)
                                    .autocorrectionDisabled()
                                    .help("Where the client ID and secret are exchanged for access tokens.")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Scope").font(.caption.weight(.semibold))
                                TextField("Optional", text: $scope, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client ID").font(.caption.weight(.semibold))
                            TextField(existing?.clientCredentials != nil ? "Saved; enter both to replace them" : "Client ID",
                                      text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client Secret").font(.caption.weight(.semibold))
                            SecureField(existing?.clientCredentials != nil ? "Saved; enter both to replace them" : "Client secret", text: $clientSecret)
                        }
                    }
                    if signIn == .token, let composed = composedToken {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(composed.first).font(.caption.weight(.semibold))
                            TextField("Saved; enter both to replace them", text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(composed.second).font(.caption.weight(.semibold))
                            SecureField(composed.second, text: $clientSecret)
                        }
                    } else if signIn == .token {
                        // A catalogue tool's header is its entry's.
                        if existing?.tokenParameter == nil, preset == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Header").font(.caption.weight(.semibold))
                                TextField("Authorization", text: $tokenHeader, axis: .horizontal).lineLimit(1)
                                    .autocorrectionDisabled()
                                    .help("The request header the service expects the token in. A token sent in Authorization goes as a bearer token unless it names its own scheme.")
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token").font(.caption.weight(.semibold))
                            SecureField(existing?.usesToken == true ? "Saved; enter a new one to replace it" : "API key or token", text: $token)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.caption.weight(.semibold))
                    TextField("Optional", text: $description, axis: .vertical).lineLimit(2...3)
                        .overlay(alignment: .topTrailing) { resetButton($description, to: existing?.defaultDescription) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions").font(.caption.weight(.semibold))
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .roundedBorderEditor()
                        .frame(height: 130)
                        .help("Optional guidance on using this connection. Do not include passwords or tokens.")
                        .overlay(alignment: .topTrailing) { resetButton($instructions, to: existing?.defaultInstructions) }
                }
                if onBack != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                // Only where a key or token can be replaced; one that signs in through the browser asks for nothing here.
                if onSecret != nil, signIn != .browser, let preset, !preset.setup.isEmpty {
                    ToolSetupSteps(title: preset.name, steps: preset.setup)
                }
            }.textFieldStyle(.roundedBorder).padding(20)
        }.frame(width: 480)
    }
    /// Puts its preset's text back in a field the person changed; saved so, the account follows that text's updates.
    @ViewBuilder private func resetButton(_ text: Binding<String>, to fallback: String?) -> some View {
        if let fallback, !fallback.isEmpty, text.wrappedValue != fallback {
            Button { text.wrappedValue = fallback } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Reset to Default; it then follows the default's updates")
                .padding(4)
        }
    }
    /// Whether the app's own adapter answers it, through the service's API rather than an MCP server.
    private var servedByApp: Bool { existing?.adapter != nil }
    /// The catalogue entry the account was made from, when it is one; its details are then edited as its fields.
    private var preset: ToolDefinition? { existing.flatMap(ToolCatalog.definition(for:)) }
    private var presetFields: [ToolField] {
        guard case .connection(let configuration)? = preset?.configuration else { return [] }
        return configuration.fields
    }
    /// Whether a new key, token or secret was entered in place of the saved one.
    private var enteredSecret: Bool {
        func filled(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return switch signIn {
        case .browser: false
        case .token: composedToken != nil ? filled(clientID) : filled(token)
        case .client: filled(clientID)
        }
    }
    /// The two values an existing connection's token is made from, when its preset composes it.
    private var composedToken: ComposedToken? {
        guard let existing, case .connection(let configuration)? = ToolCatalog.definition(for: existing)?.configuration else { return nil }
        return configuration.composedToken
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
    private func draft() throws -> ToolConnection {
        if let existing, let preset {
            // Made again from its fields, so a new address or organisation reaches all it touches, as on adding it.
            let fresh = try preset.makeConnection(id: existing.id, name: try ConversationName.validated(name), values: values)
            var record = existing.remade(as: fresh)
            record.name = try ConversationName.validated(name)
            record.description = String(description.prefix(1_000))
            record.instructions = String(instructions.prefix(20_000))
            // A key goes only where it was given: one for an address that moved is asked for again.
            if record.endpoint != existing.endpoint || record.clientCredentials != existing.clientCredentials, existing.keepsSecret, !enteredSecret {
                throw ToolConnectionError.message("Enter the key or token again for the new details.")
            }
            return record
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ToolConnectionError.message("Enter a valid HTTPS server URL.")
        }
        // A registry save can succeed before workspace refresh fails. Keep
        // the draft's identity so retry updates that account in place.
        var record = try existing ?? ToolConnection(id: newConnectionID, name: name, endpoint: url)
        record.name = try ConversationName.validated(name)
        record.description = String(description.prefix(1_000))
        record.instructions = String(instructions.prefix(20_000))
        record.tokenHeader = nil
        record.tokenParameter = nil
        record.clientCredentials = nil
        switch signIn {
        case .browser: break
        case .token where composedToken != nil:
            // Its token is made from the two values; the connection itself stays as its preset made it.
            record.tokenHeader = existing?.tokenHeader
            record.tokenScheme = existing?.tokenScheme
            if !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !clientSecret.isEmpty {
                _ = try composedToken!.compose(clientID, clientSecret)
            }
        case .token where existing?.tokenParameter != nil:
            // A token its service takes only in the address keeps going there; only its value changes.
            record.tokenParameter = existing?.tokenParameter
        case .token:
            let header = try ToolConnection.validatedTokenHeader(tokenHeader)
            let blank = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank, existing?.tokenHeader != header {
                throw ToolConnectionError.message(existing?.tokenHeader == nil ? "Enter the token." : "Enter the token again for the new header.")
            }
            record.tokenHeader = header
        case .client:
            guard let url = URL(string: tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ToolConnectionError.message("Enter the token URL.")
            }
            let exchange = try ToolConnection.validatedClientCredentials(ConnectionClientCredentials(tokenEndpoint: url, scope: scope))
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty != secret.isEmpty { throw ToolConnectionError.message("Enter both the client ID and the secret.") }
            if id.isEmpty, existing?.clientCredentials?.tokenEndpoint != exchange.tokenEndpoint {
                throw ToolConnectionError.message(existing?.clientCredentials == nil ? "Enter the client ID and secret."
                                                 : "Enter the client ID and secret again for the new token URL.")
            }
            record.clientCredentials = exchange
        }
        return record
    }
    private func finish(_ record: ToolConnection) {
        onSaved(record)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = composedToken.flatMap { try? $0.compose(clientID, clientSecret) }
        let secret: ToolConnectionSecret? = switch signIn {
        case .browser: nil
        case .token where composedToken != nil: composed.map { .token($0) }
        case .token: newToken.isEmpty ? nil : .token(newToken)
        case .client: id.isEmpty ? nil : .client(id: id, secret: clientSecret)
        }
        let switchedToBrowser = signIn == .browser && (existing?.usesToken == true || existing?.clientCredentials != nil)
        // New details for a catalogue tool connect it again, so a sign-in for the old ones is not kept using.
        let detailsChanged = existing.map { $0.endpoint != record.endpoint || $0.settings != record.settings } ?? false
        let shouldConnect = existing == nil || switchedToBrowser || secret != nil || detailsChanged
        dismiss()
        if shouldConnect {
            Task { @MainActor in
                // Present authorization after the editor sheet has dismissed.
                try? await Task.sleep(for: .milliseconds(250))
                if let secret, let onSecret { onSecret(record, secret) } else { onConnect(record) }
            }
        }
    }
}

/// A connection's status in words and a symbol, as Settings › Tools shows it.
public struct ToolConnectionStatusLabel: View {
    let status: ToolConnectionStatus

    public init(status: ToolConnectionStatus) { self.status = status }

    public var body: some View {
        switch status {
        case .managed: SettingsStatusLabel(title: Organisation.managedText, systemImage: "building.2", color: .secondary)
        case .signingIn: SettingsStatusLabel(title: "Signing in…", systemImage: "arrow.triangle.2.circlepath", color: .secondary)
        case .failed: SettingsStatusLabel(title: "Needs attention", systemImage: "exclamationmark.triangle", color: .orange)
        case .connected: SettingsStatusLabel(title: "Connected", systemImage: "checkmark.circle.fill", color: .green)
        case .tokenRequired: SettingsStatusLabel(title: "Token required", systemImage: "key", color: .secondary)
        case .credentialsRequired: SettingsStatusLabel(title: "Credentials required", systemImage: "key", color: .secondary)
        case .signInRequired: SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
        }
    }
}

/// A connected connection's status, which opens Sign Out: revoke what it signed in with at the service, where the
/// service allows it, and forget it here.
private struct ConnectedStatus: View {
    let onSignOut: () -> Void
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            ToolConnectionStatusLabel(status: .connected)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Button("Sign Out", role: .destructive) { shown = false; onSignOut() }
                .padding(12)
        }
    }
}

public struct ToolConnectionIcon: View {
    let connection: ToolConnection
    let size: CGFloat
    public var body: some View {
        Group {
            if let data = connection.iconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let tool = ToolCatalog.definition(for: connection) {
                ToolCatalogIcon(tool: tool, size: size)
            } else {
                Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(size * 0.15)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    public init(connection: ToolConnection, size: CGFloat) {
        self.connection = connection
        self.size = size
    }
}

/// A tool connection's icon in two flat tones, its logo in the text colour on a tile of the window's own grey, for
/// places where it sits among flat marks, such as the sidebar. Its logo is whichever of its tones covers less.
public struct FlatToolIcon: View {
    let connection: ToolConnection
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    public init(connection: ToolConnection, size: CGFloat) {
        self.connection = connection
        self.size = size
    }

    public var body: some View {
        let dark = colorScheme == .dark
        let tile = NSColor(white: dark ? 0.24 : 0.84, alpha: 1), ink = NSColor(white: dark ? 0.9 : 0.15, alpha: 1)
        Group {
            // Made at the pixels it is shown at, so nothing shrinks it again on screen.
            if let image = Self.image(for: connection, dark: dark, tile: tile, ink: ink, pixels: Int((size * displayScale).rounded())) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                Text(String(connection.name.prefix(1))).font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(Color(nsColor: ink))
                    .frame(width: size, height: size)
                    .background(Color(nsColor: tile))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }

    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    @MainActor private static func image(for connection: ToolConnection, dark: Bool, tile: NSColor, ink: NSColor, pixels: Int) -> NSImage? {
        let key = "\(connection.id)-\(connection.iconData?.count ?? 0)-\(dark)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let source = connection.iconData.flatMap(NSImage.init(data:)) ?? ToolCatalog.definition(for: connection).flatMap(ToolCatalogIcon.image(for:))
        guard let cg = source?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let flat = twoTone(cg, tile: tile, ink: ink, pixels: pixels) else { return nil }
        let image = NSImage(cgImage: flat, size: NSSize(width: flat.width, height: flat.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// The image in two tones: its logo, the tone that covers less, in `ink`, and the rest in `tile`. Transparent parts
    /// count as background. It is drawn larger and softened first, then, given `pixels`, shrunk to that width, so the
    /// logo's edges stay clean at the size it is shown.
    public static func twoTone(_ image: CGImage, tile: NSColor, ink: NSColor, pixels: Int? = nil) -> CGImage? {
        let source = CIImage(cgImage: image)
        let scale = max(1, 256 / max(source.extent.width, 1))
        let large = source.composited(over: CIImage(color: .white).cropped(to: source.extent))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        let extent = large.extent
        let grey = large.applyingFilter("CIPhotoEffectMono").clampedToExtent()
            .applyingGaussianBlur(sigma: scale * 0.35).cropped(to: extent)
        let context = CIContext()
        var average = [UInt8](repeating: 0, count: 4)
        context.render(grey.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]),
                       toBitmap: &average, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        // The logo is the tone that covers less: dark on a mostly light image, light on a mostly dark one.
        var mask = grey.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.55])
        if average[0] > 128 { mask = mask.applyingFilter("CIColorInvert") }
        guard let tileColour = CIColor(color: tile), let inkColour = CIColor(color: ink) else { return nil }
        var coloured = mask.applyingFilter("CIFalseColor", parameters: ["inputColor0": tileColour, "inputColor1": inkColour])
        // Halved a step at a time with Core Image's own downsampling: sharper than one big shrink, and without the dark
        // halos a Lanczos shrink rings around a light logo.
        if let pixels, pixels > 0 {
            var factor = CGFloat(pixels) / extent.width
            while factor < 0.5 {
                coloured = coloured.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5), highQualityDownsample: true)
                factor *= 2
            }
            coloured = coloured.transformed(by: CGAffineTransform(scaleX: factor, y: factor), highQualityDownsample: true)
        }
        return context.createCGImage(coloured, from: coloured.extent.integral)
    }
}

public extension View {
    /// Puts a TextEditor inside a real `.roundedBorder` field bezel, so
    /// multi-line fields match the single-line ones beside them. The bezel is
    /// translucent and its colours depend on where it sits, so it is drawn by
    /// AppKit rather than imitated.
    func roundedBorderEditor() -> some View {
        modifier(RoundedBorderEditor())
    }
}

private struct RoundedBorderEditor: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .background {
                RoundedBorderBezel(focused: focused)
                    .padding(-RoundedBorderBezel.ringMargin)
            }
    }
}

/// The bezel field never becomes first responder, so AppKit never rings it;
/// while the editor has focus the bezel draws a ring matching the one AppKit
/// gives focused single-line fields. The view reaches `ringMargin` past the
/// field so the ring is not clipped.
struct RoundedBorderBezel: NSViewRepresentable {
    static let ringMargin: CGFloat = 4
    var focused: Bool

    final class BezelView: NSView {
        private let field = NSTextField(string: "")
        private let ring = FocusRingView()
        var focused: Bool {
            get { ring.shown }
            set { ring.shown = newValue }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            field.isEditable = false
            field.isSelectable = false
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.refusesFirstResponder = true
            field.setAccessibilityElement(false)
            addSubview(field)
            addSubview(ring)
        }

        required init?(coder: NSCoder) { nil }

        // The field keeps its one-line intrinsic height under constraints or
        // autoresizing; setting its frame here lets the bezel fill the editor.
        override func layout() {
            super.layout()
            field.frame = bounds.insetBy(dx: ringMargin, dy: ringMargin)
            ring.frame = bounds
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Measured from a focused rounded field: 4 pt wide, from 3 pt outside
    /// the 6 pt-radius bezel to 1 pt inside it. Like AppKit's, it shrinks
    /// into place as it fades in, and fades out.
    final class FocusRingView: NSView {
        private let shape = CAShapeLayer()

        var shown = false {
            didSet { if shown != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            shape.fillColor = nil
            shape.lineWidth = 4
            shape.opacity = 0
            layer?.addSublayer(shape)
        }

        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                shape.strokeColor = NSColor.keyboardFocusIndicatorColor.cgColor
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            shape.path = path(outset: 0)
            CATransaction.commit()
        }

        private func path(outset: CGFloat) -> CGPath {
            let rect = bounds.insetBy(dx: ringMargin - 1 - outset, dy: ringMargin - 1 - outset)
            return CGPath(roundedRect: rect, cornerWidth: 7 + outset, cornerHeight: 7 + outset, transform: nil)
        }

        private func animate() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? shape.opacity
            shape.opacity = shown ? 1 : 0
            let group = CAAnimationGroup()
            group.duration = shown ? 0.2 : 0.12
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.animations = [fade]
            if shown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let shrink = CABasicAnimation(keyPath: "path")
                shrink.fromValue = path(outset: 8)
                shrink.toValue = path(outset: 0)
                group.animations?.append(shrink)
            }
            shape.add(group, forKey: "focus")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> BezelView { BezelView() }
    func updateNSView(_ nsView: BezelView, context: Context) { nsView.focused = focused }
}
