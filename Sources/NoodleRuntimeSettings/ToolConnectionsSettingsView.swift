import AppKit
import SwiftUI
import NoodleCore
import NoodleMCP

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
                                Text(connection.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !connection.description.isEmpty {
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if let error = store.connectionsController.errors[connection.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 12) {
                                    if connection.keepsSecret {
                                        // A token or client secret is entered in the editor; there is no sign-in to start.
                                        let what = connection.usesToken ? "Token" : "Credentials"
                                        Button(store.connectionsController.connected.contains(connection.id) ? "Change \(what)…" : "Enter \(what)…") { editing = connection }
                                            .buttonStyle(.link)
                                            .disabled(store.connectionsController.signingIn != nil || !allows(connection))
                                    } else {
                                        Button(store.connectionsController.connected.contains(connection.id) ? "Reconnect" : "Connect") { store.connectionsController.connect(connection) }
                                            .buttonStyle(.link)
                                            .disabled(store.connectionsController.signingIn != nil || !allows(connection))
                                    }
                                    Button("Edit…") { editing = connection }
                                        .buttonStyle(.link)
                                    Button("Remove") { removing = connection }
                                        .buttonStyle(.link)
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
            Text("This removes this connection from all bots and deletes its saved sign-in from Noodle. Other connections to the same service are unchanged. To revoke the provider's grant too, use its account settings.")
        }
        .alert("Tools", isPresented: Binding(get: { store.connectionsController.errorMessage != nil }, set: { if !$0 { store.connectionsController.errorMessage = nil } })) {
            Button("OK") { store.connectionsController.errorMessage = nil }
        } message: { Text(store.connectionsController.errorMessage ?? "") }
    }

    private func allows(_ connection: ToolConnection) -> Bool {
        OrganisationStatus.shared.allows(Organisation.action(for: connection))
    }

    @ViewBuilder private func connectionStatus(_ connection: ToolConnection) -> some View {
        if !allows(connection) {
            SettingsStatusLabel(title: Organisation.managedText, systemImage: "building.2", color: .secondary)
        } else if store.connectionsController.signingIn == connection.id {
            Text(store.connectionsController.signInStage.isEmpty ? (ToolConnectionService.signsInThroughBrowser(connection) ? "Signing in…" : "Checking access…") : store.connectionsController.signInStage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(store.connectionsController.signInStage)
        } else if store.connectionsController.errors[connection.id] != nil {
            SettingsStatusLabel(title: "Needs attention", systemImage: "exclamationmark.triangle", color: .orange)
        } else if store.connectionsController.connected.contains(connection.id) {
            SettingsStatusLabel(title: "Connected", systemImage: "checkmark.circle.fill", color: .green)
        } else if connection.usesToken {
            SettingsStatusLabel(title: "Token required", systemImage: "key", color: .secondary)
        } else if connection.clientCredentials != nil || connection.awsSigning != nil || connection.googleServiceAccount != nil {
            SettingsStatusLabel(title: "Credentials required", systemImage: "key", color: .secondary)
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
    private enum SignIn: Hashable { case browser, token, client, aws, google }
    @Environment(\.dismiss) private var dismiss
    @State private var signIn: SignIn
    @State private var tokenHeader: String
    @State private var token = ""
    @State private var tokenEndpoint: String
    @State private var scope: String
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var sessionToken = ""
    @State private var serviceAccountKey = ""
    @State private var name: String
    @State private var endpoint: String
    @State private var description: String
    @State private var instructions: String
    @State private var error: String?
    @State private var newConnectionID = UUID()
    @State private var saving = false
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
        _signIn = State(initialValue: existing?.usesToken == true ? .token : existing?.clientCredentials != nil ? .client
                        : existing?.awsSigning != nil ? .aws : existing?.googleServiceAccount != nil ? .google : .browser)
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
                Text(existing != nil ? "Edit MCP" : "Custom MCP").font(.headline)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCP Server URL").font(.caption.weight(.semibold))
                    TextField("https://…", text: $endpoint, axis: .horizontal).lineLimit(1)
                        .autocorrectionDisabled().disabled(existing != nil)
                }
                if onSecret != nil {
                    if let steps = existing.flatMap(ToolCatalog.definition(for:))?.setup, !steps.isEmpty {
                        ToolSetupSteps(steps: steps)
                    }
                    // An adapter connection proves itself the way its adapter expects; only its values change here.
                    if existing?.adapter == nil {
                        Picker("Sign-in", selection: $signIn) {
                            Text("Browser").tag(SignIn.browser)
                            Text("Token").tag(SignIn.token)
                            Text("Client ID & Secret").tag(SignIn.client)
                        }
                        .pickerStyle(.segmented)
                    }
                    if signIn == .google {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Service Account Key").font(.caption.weight(.semibold))
                            ServiceAccountKeyField(key: $serviceAccountKey, replacing: true)
                        }
                    }
                    if signIn == .aws {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Access Key ID").font(.caption.weight(.semibold))
                            TextField("Saved; enter a new key to replace it", text: $clientID, axis: .horizontal).lineLimit(1).autocorrectionDisabled()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Secret Access Key").font(.caption.weight(.semibold))
                            SecureField("Secret access key", text: $clientSecret)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Session Token").font(.caption.weight(.semibold))
                            SecureField("Only for temporary credentials", text: $sessionToken)
                        }
                    }
                    if signIn == .client {
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
                        if existing?.tokenParameter == nil {
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
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions").font(.caption.weight(.semibold))
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .roundedBorderEditor()
                        .frame(height: 130)
                        .help("Optional guidance for bots using this connection. Do not include passwords or tokens.")
                }
                Text(signIn == .browser ? "MCP connection · Sign-in opens in your browser."
                     : "MCP connection · Kept in Keychain and used for every request.")
                    .font(.caption).foregroundStyle(.secondary)
                if existing != nil {
                    Text("Changes apply to every bot using this connection.").font(.caption).foregroundStyle(.secondary)
                }
                if onBack != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(20)
        }.frame(width: 480)
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
        case .browser, .google: break
        case .aws:
            // Its signing stays as its preset made it; only the key can be replaced.
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty != clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolConnectionError.message("Enter both the access key ID and the secret access key.")
            }
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
        case .aws: id.isEmpty ? nil : .aws(accessKeyID: id, secretAccessKey: clientSecret, sessionToken: sessionToken)
        case .google: serviceAccountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .google(serviceAccountKey)
        }
        let switchedToBrowser = signIn == .browser && (existing?.usesToken == true || existing?.clientCredentials != nil)
        let shouldConnect = existing == nil || switchedToBrowser || secret != nil
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

/// Where a Google service account's JSON key is pasted, or read from the file Google gave. What is pasted shows
/// only that a key is there, never its contents.
struct ServiceAccountKeyField: View {
    @Binding var key: String
    var replacing = false
    @State private var choosing = false

    var body: some View {
        HStack {
            Text(key.isEmpty ? (replacing ? "Saved; choose a new key file to replace it" : "No key chosen") : "Key file chosen")
                .foregroundStyle(key.isEmpty ? .secondary : .primary)
            Spacer()
            Button("Paste") { key = NSPasteboard.general.string(forType: .string) ?? "" }
            Button("Choose Key File…") { choosing = true }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            key = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
