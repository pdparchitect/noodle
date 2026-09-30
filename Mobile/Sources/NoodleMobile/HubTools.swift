import AuthenticationServices
import GameController
import HubLink
import SwiftUI

/// Where a tool connection's sign-in comes back to this phone.
private let signInScheme = "noodle-mobile"

extension HubChats {
    func loadTools() async throws {
        try await loadConnections()
        try await loadComputers()
        try await loadBrowsers()
    }

    func loadConnections() async throws {
        guard case .connections(let listed) = try await pairing.request(.connections) else { throw LinkError("The Hub sent an unexpected answer.") }
        connections = listed
    }

    func loadComputers() async throws {
        guard case .computers(let listed) = try await pairing.request(.computers) else { throw LinkError("The Hub sent an unexpected answer.") }
        computers = listed
    }

    func loadBrowsers() async throws {
        guard case .browsers(let listed) = try await pairing.request(.browsers) else { throw LinkError("The Hub sent an unexpected answer.") }
        browsers = listed
    }

    // MARK: Connections

    @discardableResult func saveConnection(_ draft: LinkConnectionDraft) async throws -> LinkConnection {
        guard case .connection(let saved) = try await pairing.request(.saveConnection(draft)) else { throw LinkError("The Hub sent an unexpected answer.") }
        try await loadConnections()
        return saved
    }

    func deleteConnection(_ connection: LinkConnection) async throws {
        _ = try await pairing.request(.deleteConnection(id: connection.id))
        try await loadConnections()
    }

    /// Asks the Hub to sign a connection in; it sends back the page to open, which `signIn(_:page:)` shows.
    func startSignIn(_ connection: LinkConnection) async throws {
        try await pairing.signIn(connectionID: connection.id, redirect: URL(string: "\(signInScheme)://mcp/oauth/callback")!)
    }

    /// Shows the sign-in page in the phone's browser and hands the Hub the address it came back to.
    func signIn(_ id: UUID, page: URL) async {
        do {
            guard pairing.takeSignInPage(for: id, url: page) else {
                throw LinkError("Noodle did not open a sign-in page it had not asked for.")
            }
            let callback = try await SignInBrowser.open(page, scheme: signInScheme)
            _ = try await pairing.request(.finishSignIn(connectionID: id, callback: callback))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The services the Hub offers ready to connect.
    func toolCatalog() async throws -> [LinkToolPreset] {
        guard case .toolCatalog(let presets) = try await pairing.request(.toolCatalog) else { throw LinkError("The Hub sent an unexpected answer.") }
        return presets
    }

    // MARK: Computers and browsers

    func computerTemplates() async throws -> [LinkComputerTemplate] {
        guard case .computerTemplates(let templates) = try await pairing.request(.computerTemplates) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return templates
    }

    /// Makes a computer, which may first download its image; the Hub says when it is ready.
    func createComputer(_ draft: LinkComputerDraft) async throws -> LinkComputer {
        let id = UUID()
        let made = try await withCheckedThrowingContinuation { continuation in
            making[id] = continuation
            Task {
                do { _ = try await pairing.request(.createComputer(requestID: id, draft)) }
                catch { making.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
        try await loadComputers()
        return made
    }

    func deleteComputer(_ computer: LinkComputer) async throws {
        _ = try await pairing.request(.deleteComputer(id: computer.id))
        try await loadComputers()
    }

    func createBrowser(named name: String) async throws {
        _ = try await pairing.request(.createBrowser(LinkBrowserDraft(name: name)))
        try await loadBrowsers()
    }

    func deleteBrowser(_ browser: LinkBrowser) async throws {
        _ = try await pairing.request(.deleteBrowser(id: browser.id))
        try await loadBrowsers()
    }

    // MARK: Assignments

    /// Gives a bot one of this user's connections, computers or browsers, or takes it away.
    func toggle(_ kind: HubTool, _ id: UUID, for agent: LinkBot) async throws {
        switch kind {
        case .connection:
            var ids = Set(connections.filter { $0.botIDs.contains(agent.id) }.map(\.id))
            if ids.remove(id) == nil { ids.insert(id) }
            _ = try await pairing.request(.assignConnections(botID: agent.id, connectionIDs: Array(ids)))
            try await loadConnections()
        case .computer:
            var ids = Set(computers.filter { $0.botIDs.contains(agent.id) }.map(\.id))
            if ids.remove(id) == nil { ids.insert(id) }
            _ = try await pairing.request(.assignComputers(botID: agent.id, computerIDs: Array(ids)))
            try await loadComputers()
        case .browser:
            var ids = Set(browsers.filter { $0.botIDs.contains(agent.id) }.map(\.id))
            if ids.remove(id) == nil { ids.insert(id) }
            _ = try await pairing.request(.assignBrowsers(botID: agent.id, browserIDs: Array(ids)))
            try await loadBrowsers()
        }
    }

    /// Opens the live view of what a link in the bot's conversation points at.
    func openSurface(_ attachment: LinkAttachment, in conversation: some HubConversation) async throws -> LinkChannel {
        try await pairing.channel(.openSurface(conversationID: conversation.conversationID, attachmentID: attachment.id))
    }

    /// Opens a noodlet a bot shared to run on this phone.
    func openNoodlet(_ attachment: LinkAttachment, in conversation: some HubConversation) async throws -> LinkNoodletSession {
        let pairing = pairing
        return try await LinkNoodletSession.open(conversationID: conversation.conversationID, attachmentID: attachment.id) {
            try await pairing.request($0)
        }
    }

    /// Where this Hub's noodlets are kept on this phone; the system clears it when space runs low.
    var noodletCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noodlets/\(pairing.directory.lastPathComponent)")
    }

    /// The latest picture of what a link points at, for a card that carries none, as a noodlet's.
    func picture(for attachment: LinkAttachment, in conversation: some HubConversation) async throws -> Data? {
        if let known = pictures[attachment.id] { return known }
        guard case .picture(let data) = try await pairing.request(.linkPreview(conversationID: conversation.conversationID, attachmentID: attachment.id))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        pictures[attachment.id] = data
        return data
    }
}

enum HubTool { case connection, computer, browser }

/// The system sign-in sheet, which keeps the browser's own sign-ins and returns on the callback scheme.
@MainActor private enum SignInBrowser {
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    /// The sheet showing now, kept until it finishes.
    private static var showing: (session: ASWebAuthenticationSession, anchor: Anchor)?

    static func open(_ page: URL, scheme: String) async throws -> URL {
        let anchor = Anchor()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme(scheme)) { url, error in
                Task { @MainActor in showing = nil }
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? LinkError("Sign-in was cancelled.")) }
            }
            session.presentationContextProvider = anchor
            showing = (session, anchor)
            if !session.start() {
                showing = nil
                continuation.resume(throwing: LinkError("The sign-in page could not open."))
            }
        }
    }
}

// MARK: - Screens

/// A bot's tool connections, computers or browsers: yours on the Hub, ticked when the bot may use them.
struct HubToolsScreen: View {
    let chats: HubChats
    let agent: LinkBot
    let kind: HubTool
    @State private var adding = false
    @State private var busy: UUID?
    @State private var problem: String?

    private var title: String {
        switch kind {
        case .connection: "Tools"
        case .computer: "Computers"
        case .browser: "Browsers"
        }
    }

    private var rows: [(id: UUID, name: String, detail: String?, assigned: Bool, needsSignIn: Bool)] {
        switch kind {
        case .connection:
            chats.connections.map { ($0.id, $0.draft.name, $0.problem, $0.botIDs.contains(agent.id), !$0.signedIn) }
        case .computer:
            chats.computers.map { ($0.id, $0.name, $0.state, $0.botIDs.contains(agent.id), false) }
        case .browser:
            chats.browsers.map { ($0.id, $0.name, $0.paused ? "Paused" : nil, $0.botIDs.contains(agent.id), false) }
        }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text("None on this Hub yet").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                HStack {
                    Button {
                        run(row.id) { try await chats.toggle(kind, row.id, for: agent) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).foregroundStyle(.primary)
                                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if busy == row.id { ProgressView() }
                            else if row.assigned { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    if row.needsSignIn, let connection = chats.connections.first(where: { $0.id == row.id }) {
                        Button("Sign In") { run(row.id) { try await chats.startSignIn(connection) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { run(row.id) { try await delete(row.id) } }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NewHubToolSheet(chats: chats, agent: agent, kind: kind)
        }
        .wordmarkRefreshable { try? await chats.loadTools() }
    }

    private func delete(_ id: UUID) async throws {
        switch kind {
        case .connection: if let item = chats.connections.first(where: { $0.id == id }) { try await chats.deleteConnection(item) }
        case .computer: if let item = chats.computers.first(where: { $0.id == id }) { try await chats.deleteComputer(item) }
        case .browser: if let item = chats.browsers.first(where: { $0.id == id }) { try await chats.deleteBrowser(item) }
        }
    }

    private func run(_ id: UUID, _ action: @escaping () async throws -> Void) {
        busy = id
        problem = nil
        Task {
            defer { busy = nil }
            do { try await action() } catch { problem = error.localizedDescription }
        }
    }
}

extension [LinkComputerTemplate] {
    /// A new computer's name after its kind changes: it follows the kind's name until the user types their own.
    func renamed(_ name: String, from old: String, to new: String) -> String {
        guard name == (first { $0.id == old }?.name ?? ""), let named = first(where: { $0.id == new })?.name else { return name }
        return named
    }
}

/// Adds a tool, computer or browser on the Hub and gives it to the bot.
private struct NewHubToolSheet: View {
    let chats: HubChats
    let agent: LinkBot
    let kind: HubTool

    var body: some View {
        if kind == .connection { NewToolSheet(chats: chats, agent: agent) }
        else { NewMachineSheet(chats: chats, agent: agent, kind: kind) }
    }
}

private struct NewMachineSheet: View {
    let chats: HubChats
    let agent: LinkBot
    let kind: HubTool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var templates: [LinkComputerTemplate] = []
    @State private var template = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if kind == .computer {
                    Picker("Kind", selection: $template) {
                        ForEach(templates) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Name", text: $name)
                if working, kind == .computer { ProgressView("Creating…") }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(kind == .computer ? "New Computer" : "New Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(working || !canCreate)
                }
            }
            .task {
                guard kind == .computer else { return }
                do {
                    templates = try await chats.computerTemplates()
                    if let first = templates.first { template = first.id }
                } catch { problem = error.localizedDescription }
            }
            .onChange(of: template) { old, new in name = templates.renamed(name, from: old, to: new) }
        }
    }

    private var canCreate: Bool {
        let named = !name.trimmingCharacters(in: .whitespaces).isEmpty
        return kind == .computer ? named && !template.isEmpty : named
    }

    private func create() {
        working = true
        problem = nil
        let name = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { working = false }
            do {
                if kind == .computer {
                    let made = try await chats.createComputer(LinkComputerDraft(template: template, name: name))
                    try await chats.toggle(.computer, made.id, for: agent)
                } else {
                    try await chats.createBrowser(named: name)
                    if let made = chats.browsers.last(where: { $0.name == name && !$0.botIDs.contains(agent.id) }) {
                        try await chats.toggle(.browser, made.id, for: agent)
                    }
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The services the Hub offers, to add one and sign in; your own MCP server comes last.
private struct NewToolSheet: View {
    let chats: HubChats
    let agent: LinkBot
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [LinkToolPreset] = []
    @State private var loading = true
    @State private var search = ""
    @State private var adding: String?
    /// A retried service keeps the connection its first try saved, as on the Mac.
    @State private var attempts: [String: UUID] = [:]
    @State private var problem: String?

    private var shown: [LinkToolPreset] {
        let terms = search.split(whereSeparator: \.isWhitespace)
        return presets.filter { preset in
            let text = [preset.name, preset.summary, preset.badge ?? ""].joined(separator: " ")
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem { Text(problem).foregroundStyle(.red) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                ForEach(shown) { preset in
                    Button { add(preset) } label: { ToolPresetRow(preset: preset, adding: adding == preset.id) }
                }
                Section {
                    NavigationLink("Custom MCP Server") { CustomToolForm(onAdd: connect) }
                }
            }
            .disabled(adding != nil)
            .searchable(text: $search, prompt: "Search tools")
            .navigationTitle("New Tool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                defer { loading = false }
                // A Hub from before the catalogue refuses the request; custom servers still work there.
                presets = (try? await chats.toolCatalog()) ?? []
            }
        }
    }

    private func add(_ preset: LinkToolPreset) {
        let id = attempts[preset.id] ?? UUID()
        attempts[preset.id] = id
        adding = preset.id
        problem = nil
        Task {
            defer { adding = nil }
            do {
                try await connect(LinkConnectionDraft(id: id, name: availableName(preset.name, retrying: id), endpoint: preset.endpoint,
                                                      description: preset.summary, instructions: preset.instructions))
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Every addition is its own account, so a second Notion is "Notion 2".
    private func availableName(_ name: String, retrying id: UUID) -> String {
        if let saved = chats.connections.first(where: { $0.id == id }) { return saved.draft.name }
        let taken = chats.connections.map(\.draft.name)
        var candidate = name, suffix = 2
        while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Saves the connection, gives it to the bot and starts signing it in.
    private func connect(_ draft: LinkConnectionDraft) async throws {
        let saved = try await chats.saveConnection(draft)
        if chats.connections.first(where: { $0.id == saved.id })?.botIDs.contains(agent.id) != true {
            try await chats.toggle(.connection, saved.id, for: agent)
        }
        if let connection = chats.connections.first(where: { $0.id == saved.id }) { try await chats.startSignIn(connection) }
        dismiss()
    }
}

private struct ToolPresetRow: View {
    let preset: LinkToolPreset
    let adding: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name).foregroundStyle(.primary)
                    if let badge = preset.badge {
                        Text(badge).font(.caption2).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if adding { ProgressView() }
        }
    }

    @ViewBuilder private var icon: some View {
        if let data = preset.icon, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Text(String(preset.name.prefix(1))).font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
    }
}

/// Your own MCP server, by name and address.
private struct CustomToolForm: View {
    let onAdd: (LinkConnectionDraft) async throws -> Void
    @State private var name = ""
    @State private var address = ""
    /// A retry changes the connection the first try saved.
    @State private var id = UUID()
    @State private var working = false
    @State private var problem: String?

    private var endpoint: URL? {
        URL(string: address.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("MCP Server URL", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Custom MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: add)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || endpoint == nil)
            }
        }
    }

    private func add() {
        guard let endpoint else { return }
        working = true
        problem = nil
        let draft = LinkConnectionDraft(id: id, name: name.trimmingCharacters(in: .whitespaces), endpoint: endpoint)
        Task {
            defer { working = false }
            do { try await onAdd(draft) } catch { problem = error.localizedDescription }
        }
    }
}

/// A link a bot shared to a browser tab, computer or noodlet, shown live and usable from the phone.
struct LiveSurfaceScreen: View {
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    /// For a noodlet this phone can run itself, switches to running it here.
    var runHere: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?
    /// The keys a game declared: shown as a controller in place of the keyboard.
    @State private var controls: Gamepad?
    @State private var showsControls = true
    @State private var hardware = HardwareGamepad()
    @Environment(\.verticalSizeClass) private var verticalSize

    /// Sideways, the picture gets the whole screen and the buttons float over its corners.
    private var fullScreen: Bool { verticalSize == .compact }

    /// What goes on the screen: everything, or with a controller in hand only what it has no room for.
    private var screenControls: Gamepad? {
        guard let controls, showsControls else { return nil }
        guard let controller = hardware.controller else { return controls }
        return controls.onScreen(with: controller)
    }

    private func hold(_ change: GamepadKeyChange) {
        channel?.send(LinkSurface.control(.input(.hold(key: change.key, pressed: change.pressed))))
    }

    /// A game shows its controller from the start; the keyboard stays beside it for typing a name or a word.
    @ViewBuilder private var inputButtons: some View {
        if controls != nil {
            Button("Controls", systemImage: showsControls ? "gamecontroller.fill" : "gamecontroller") { showsControls.toggle() }
        }
        Button("Keyboard", systemImage: "keyboard") { feed.toggleKeyboard() }
        if let runHere { Button("Run on \(UIDevice.current.model)", systemImage: "iphone", action: runHere) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
                    .ignoresSafeArea(edges: fullScreen ? .all : .bottom)
                if let screenControls, showing { GamepadOverlay(gamepad: screenControls, onKey: hold) }
                if !showing {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                    else { ProgressView().tint(.white) }
                }
            }
            .background(.black)
            .overlay(alignment: .top) {
                if fullScreen {
                    HStack {
                        Button("Done") { dismiss() }
                        Spacer()
                        inputButtons.labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass).padding(.horizontal, 12)
                }
            }
            .navigationTitle(attachment.card?.title ?? "Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(fullScreen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) { inputButtons }
            }
        }
        .task { await follow() }
        .onDisappear { hardware.detach(); channel?.cancel() }
    }

    private func follow() async {
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await chats.openSurface(attachment, in: thread)
            self.channel = channel
            defer { channel.cancel() }
            for try await frame in channel.frames {
                switch LinkSurface.message(frame) {
                case .packets(let packets)?: feed.receive(packets)
                case .failed(let reason)?: failure = reason; showing = false
                case .controls(let gamepad)?:
                    controls = gamepad
                    hardware.attach(gamepad, onKey: hold)
                default: break
                }
            }
            if !showing { failure = "The Hub could not show this." }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A game controller in hand, playing the keys a game declared: the d-pad and left stick steer
/// its first pad, the right stick its second, and buttons go by position from the one under the thumb.
@MainActor @Observable final class HardwareGamepad {
    /// What the controller in hand has, or nil with none. A connected controller counts once it
    /// is used: the simulator always lists a virtual one, and a paired one may be in a drawer.
    private(set) var controller: GamepadController?
    @ObservationIgnored private var connectedController: GamepadController?
    @ObservationIgnored private var gamepad: Gamepad?
    @ObservationIgnored private var onKey: (GamepadKeyChange) -> Void = { _ in }
    @ObservationIgnored private var connected: GCController?
    /// What each stick and button holds, so a d-pad and a stick steering the same pad add up.
    @ObservationIgnored private var held: [String: Set<String>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(_ gamepad: Gamepad, onKey: @escaping (GamepadKeyChange) -> Void) {
        prepare(gamepad, onKey: onKey)
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.connect() }
                })
            }
        }
        connect()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        use(nil)
    }

    func prepare(_ gamepad: Gamepad, onKey: @escaping (GamepadKeyChange) -> Void) {
        self.gamepad = gamepad
        self.onKey = onKey
    }

    /// What the connected controller has, taking over once it is used; nil gives the screen back.
    func offer(_ next: GamepadController?) {
        set([:])
        connectedController = next
        controller = nil
    }

    private func connect() { use(GCController.current ?? GCController.controllers().first) }

    private func use(_ next: GCController?) {
        if let connected, connected !== next { release(connected) }
        connected = next
        guard let next, let gamepad else { offer(nil); return }
        let pads = gamepad.pads
        func steer(_ source: String, pad index: Int) -> GCControllerDirectionPadValueChangedHandler? {
            guard index < pads.count else { return nil }
            return { [weak self] _, x, y in MainActor.assumeIsolated { self?.set(source, pads[index].held(x: x, y: y)) } }
        }
        func press(_ source: String, _ key: String?) -> GCControllerButtonValueChangedHandler? {
            guard let key else { return nil }
            return { [weak self] _, _, pressed in MainActor.assumeIsolated { self?.set(source, pressed ? [key] : []) } }
        }
        var buttons: [GCControllerButtonInput]
        if let full = next.extendedGamepad {
            full.dpad.valueChangedHandler = steer("dpad", pad: 0)
            full.leftThumbstick.valueChangedHandler = steer("left stick", pad: 0)
            full.rightThumbstick.valueChangedHandler = steer("right stick", pad: 1)
            buttons = [full.buttonA, full.buttonB, full.buttonX, full.buttonY, full.leftShoulder, full.rightShoulder,
                       full.leftTrigger, full.rightTrigger]
            full.buttonMenu.valueChangedHandler = press("menu", gamepad.menu)
            offer(GamepadController(pads: 2, buttons: buttons.indices.map(String.init), menu: true))
        } else if let remote = next.microGamepad {
            remote.dpad.valueChangedHandler = steer("dpad", pad: 0)
            buttons = [remote.buttonA, remote.buttonX]
            remote.buttonMenu.valueChangedHandler = press("menu", gamepad.menu)
            offer(GamepadController(pads: 1, buttons: buttons.indices.map(String.init), menu: true))
        } else {
            offer(nil)
            return
        }
        for (index, button) in buttons.enumerated() {
            button.pressedChangedHandler = press("button \(index)", index < gamepad.buttons.count ? gamepad.buttons[index].key : nil)
        }
    }

    private func release(_ old: GCController) {
        if let full = old.extendedGamepad {
            [full.dpad, full.leftThumbstick, full.rightThumbstick].forEach { $0.valueChangedHandler = nil }
            [full.buttonA, full.buttonB, full.buttonX, full.buttonY, full.leftShoulder, full.rightShoulder, full.leftTrigger,
             full.rightTrigger].forEach { $0.pressedChangedHandler = nil }
            full.buttonMenu.valueChangedHandler = nil
        } else if let remote = old.microGamepad {
            remote.dpad.valueChangedHandler = nil
            [remote.buttonA, remote.buttonX].forEach { $0.pressedChangedHandler = nil }
            remote.buttonMenu.valueChangedHandler = nil
        }
    }

    func set(_ source: String, _ keys: Set<String>) {
        if !keys.isEmpty, controller == nil { controller = connectedController }
        var next = held
        next[source] = keys
        set(next)
    }

    private func set(_ next: [String: Set<String>]) {
        let before = held.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        held = next
        let after = next.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        GamepadKeyChange.changes(from: before, to: after).forEach(onKey)
    }
}

extension LinkAttachment {
    enum LiveKind { case browser, computer, noodlet }

    /// What a link to something live a bot shared points at: a browser, a computer or a noodlet.
    var liveKind: LiveKind? {
        guard let scheme = url?.scheme?.lowercased() else { return nil }
        let kinds: [(String, LiveKind)] = [("noodlebrowser", .browser), ("noodlecomputer", .computer), ("noodlet", .noodlet)]
        return kinds.first { scheme == $0.0 || scheme.hasPrefix($0.0 + "-") }?.1
    }

    var isLive: Bool { liveKind != nil }

    /// Links and voice messages open on their own; other files swipe together.
    var joinsPreviewGallery: Bool { url == nil && voice == nil }

    /// The files of a message you swipe through once one of them opens.
    static func previewGallery(opening attachment: LinkAttachment, among group: [LinkAttachment]) -> [LinkAttachment] {
        attachment.joinsPreviewGallery ? group.filter(\.joinsPreviewGallery) : [attachment]
    }

    /// A message's attachments that sit on their own, and the files laid out together as one gallery.
    static func arranged(_ attachments: [LinkAttachment]) -> (alone: [LinkAttachment], together: [LinkAttachment]) {
        (attachments.filter { !$0.joinsPreviewGallery }, attachments.filter(\.joinsPreviewGallery))
    }
}
