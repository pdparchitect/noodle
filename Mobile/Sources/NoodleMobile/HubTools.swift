import AuthenticationServices
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

    /// Shared links use the same metadata as their cards, without starting their live views.
    func sharedAttachment(_ attachment: LinkAttachment, in conversation: some HubConversation) async -> LinkAttachment {
        if let known = cards[attachment.id] {
            var resolved = attachment
            resolved.card = known
            return resolved
        }
        let pairing = pairing
        var resolved = await attachment.resolvingCard(in: conversation.conversationID) { try await pairing.request($0) }
        if resolved.card?.image == nil, let image = try? await picture(for: attachment, in: conversation) {
            if resolved.card == nil { resolved.card = LinkCardInfo(title: attachment.liveTitle) }
            resolved.card?.image = image
        }
        if let card = resolved.card { cards[attachment.id] = card }
        return resolved
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

/// A new computer or browser is named for its bot, as in "Chloe’s Computer".
func companionName(_ noun: String, for bot: String) -> String {
    let bot = bot.trimmingCharacters(in: .whitespacesAndNewlines)
    return bot.isEmpty ? noun : "\(bot)’s \(noun)"
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
    @State private var name: String
    @State private var templates: [LinkComputerTemplate] = []
    @State private var template = ""
    @State private var working = false
    @State private var problem: String?

    init(chats: HubChats, agent: LinkBot, kind: HubTool) {
        self.chats = chats
        self.agent = agent
        self.kind = kind
        _name = State(initialValue: companionName(kind == .computer ? "Computer" : "Browser", for: agent.name))
    }

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
    /// A game brought back from the TV to the phone.
    @State private var onPhone = false
    @State private var tvAvailable = false
    @State private var connectingTV = false
    @State private var gameMenu = GameMenu()
    @Environment(\.noodletMenu) private var noodletMenu
    @Environment(\.verticalSizeClass) private var verticalSize

    /// Sideways, the picture gets the whole screen and the buttons float over its corners.
    private var fullScreen: Bool { verticalSize == .compact || onTV }

    /// A game plays on a connected TV, and the phone is its controller.
    private var onTV: Bool { ExternalScreen.plays(controls, available: tvAvailable, onPhone: onPhone) }

    /// What goes on the screen: everything, or with a controller in hand only what it has no room for.
    private var screenControls: Gamepad? {
        guard let controls, showsControls || onTV else { return nil }
        guard let controller = hardware.controller else { return controls }
        return controls.onScreen(with: controller)
    }

    private func hold(_ change: GamepadKeyChange) {
        channel?.send(LinkSurface.control(.input(.hold(key: change.key, pressed: change.pressed))))
    }

    /// A game shows its controller from the start; the keyboard stays beside it for typing a name or a word.
    @ViewBuilder private var inputButtons: some View {
        if controls != nil {
            TVButton(onTV: onTV, available: tvAvailable, onPhone: $onPhone, connecting: $connectingTV)
        }
        if !onTV {
            if controls != nil {
                Button("Controls", systemImage: showsControls ? "gamecontroller.fill" : "gamecontroller") { showsControls.toggle() }
            }
            Button("Keyboard", systemImage: "keyboard") { feed.toggleKeyboard() }
        }
        if let runHere { Button("Run on \(UIDevice.current.model)", systemImage: "iphone", action: runHere) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if onTV {
                    Color.black.ignoresSafeArea()
                    if screenControls == nil, showing { ConnectedControllersView() }
                } else {
                    SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
                        .ignoresSafeArea(edges: fullScreen ? .all : .bottom)
                }
                if let screenControls, showing { GamepadOverlay(gamepad: screenControls, onKey: hold) }
                if !onTV { GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu).ignoresSafeArea() }
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
        // The TV's view tells the Hub its size, so the game is drawn for the TV.
        .externalScreen(enabled: Binding(get: { controls != nil && !onPhone }, set: { onPhone = !$0 }), available: $tvAvailable) {
            SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
            GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu)
        }
        .tvConnectionAlert(isPresented: $connectingTV)
        .task { await follow() }
        // The phone turns sideways as a controller does.
        .onChange(of: onTV) {
            ScreenOrientation.hold(onTV ? .landscape : nil)
        }
        .onChange(of: NoodletPlayer.keepsAwake(onTV: onTV, controllerInUse: hardware.controller != nil), initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            hardware.detach(); channel?.cancel(); ScreenOrientation.hold(nil)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func follow() async {
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await chats.openSurface(attachment, in: thread)
            self.channel = channel
            defer { channel.cancel() }
            // A noodlet with no keys still gets the View button's menu.
            if attachment.liveKind == .noodlet {
                hardware.attach(Gamepad(), onKey: hold)
                gameMenu.follow(hardware: hardware, menu: { noodletMenu }, close: { dismiss() })
            }
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

extension LinkAttachment {
    enum LiveKind { case browser, computer, noodlet }

    /// What a link to something live a bot shared points at: a browser, a computer or a noodlet.
    var liveKind: LiveKind? {
        guard let scheme = url?.scheme?.lowercased() else { return nil }
        let kinds: [(String, LiveKind)] = [("noodlebrowser", .browser), ("noodlecomputer", .computer), ("noodlet", .noodlet)]
        return kinds.first { scheme == $0.0 || scheme.hasPrefix($0.0 + "-") }?.1
    }

    var isLive: Bool { liveKind != nil }

    /// A web page a bot shared, shown as the card a link in a message gets rather than as its bookmark file.
    var webLink: URL? { url.flatMap { LinkPreview.isPublicWeb($0) ? $0 : nil } }

    /// What a live link points at, as on the Mac: a computer whichever view, a browser by its tab, a noodlet.
    private var liveKey: String? {
        guard let liveKind, let url, let id = url.host?.lowercased() else { return nil }
        let tab = liveKind == .browser ? URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tab" }?.value?.lowercased() : nil
        return "\(liveKind):\(id):\(tab ?? "")"
    }

    /// One entry per computer, browser tab or noodlet, keeping its most recent share.
    static func shared(newestFirst attachments: [LinkAttachment]) -> [LinkAttachment] {
        var seen = Set<String>()
        return attachments.filter { $0.liveKey.map { seen.insert($0).inserted } ?? false }
    }

    /// Resolves metadata for a live link whose share did not include its card.
    func resolvingCard(in conversationID: UUID, request: @Sendable (LinkRequest) async throws -> LinkResponse) async -> LinkAttachment {
        guard isLive, card == nil else { return self }
        guard case .linkCard(let card?) = try? await request(.linkCard(conversationID: conversationID, attachmentID: id)) else { return self }
        var resolved = self
        resolved.card = card
        return resolved
    }

    var liveTitle: String { card?.title ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent }

    var liveKindName: String {
        switch liveKind {
        case .browser: "Browser"
        case .computer: "Computer"
        case .noodlet, nil: "Noodlet"
        }
    }

    var liveSymbol: String {
        switch liveKind {
        case .noodlet: "square.grid.2x2"
        case .browser: card?.symbol ?? "globe"
        case .computer, nil: card?.symbol ?? "desktopcomputer"
        }
    }

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
