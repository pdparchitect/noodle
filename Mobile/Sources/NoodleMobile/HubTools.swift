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
        _ = try await pairing.request(.signIn(connectionID: connection.id, redirect: URL(string: "\(signInScheme)://mcp/oauth/callback")!))
    }

    /// Shows the sign-in page in the phone's browser and hands the Hub the address it came back to.
    func signIn(_ id: UUID, page: URL) async {
        do {
            let callback = try await SignInBrowser.open(page, scheme: signInScheme)
            _ = try await pairing.request(.finishSignIn(connectionID: id, callback: callback))
        } catch {
            self.error = error.localizedDescription
        }
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
    func openSurface(_ attachment: LinkAttachment, in agent: LinkBot) async throws -> LinkChannel {
        try await pairing.channel(.openSurface(conversationID: agent.conversationID, attachmentID: attachment.id))
    }

    /// The latest picture of what a link points at, for a card that carries none, as a noodlet's.
    func picture(for attachment: LinkAttachment, in agent: LinkBot) async throws -> Data? {
        if let known = pictures[attachment.id] { return known }
        guard case .picture(let data) = try await pairing.request(.linkPreview(conversationID: agent.conversationID, attachmentID: attachment.id))
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
        .refreshable { try? await chats.loadTools() }
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

/// Adds a connection, computer or browser on the Hub and gives it to the bot.
private struct NewHubToolSheet: View {
    let chats: HubChats
    let agent: LinkBot
    let kind: HubTool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
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
                if kind == .connection {
                    TextField("MCP Server URL", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if working, kind == .computer { ProgressView("Creating…") }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(kind == .connection ? "New Tool" : kind == .computer ? "New Computer" : "New Browser")
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
                    if let first = templates.first { template = first.id; if name.isEmpty { name = first.name } }
                } catch { problem = error.localizedDescription }
            }
        }
    }

    private var canCreate: Bool {
        let named = !name.trimmingCharacters(in: .whitespaces).isEmpty
        switch kind {
        case .connection: return named && URL(string: address)?.scheme == "https"
        case .computer: return named && !template.isEmpty
        case .browser: return named
        }
    }

    private func create() {
        working = true
        problem = nil
        let name = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { working = false }
            do {
                switch kind {
                case .connection:
                    guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return }
                    let saved = try await chats.saveConnection(LinkConnectionDraft(name: name, endpoint: url))
                    try await chats.toggle(.connection, saved.id, for: agent)
                    if let connection = chats.connections.first(where: { $0.id == saved.id }) { try await chats.startSignIn(connection) }
                case .computer:
                    let made = try await chats.createComputer(LinkComputerDraft(template: template, name: name))
                    try await chats.toggle(.computer, made.id, for: agent)
                case .browser:
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

/// A link a bot shared to a browser tab, computer or noodlet, shown live and usable from the phone.
struct LiveSurfaceScreen: View {
    let chats: HubChats
    let agent: LinkBot
    let attachment: LinkAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?
    @Environment(\.verticalSizeClass) private var verticalSize

    /// Sideways, the picture gets the whole screen and the buttons float over its corners.
    private var fullScreen: Bool { verticalSize == .compact }

    var body: some View {
        NavigationStack {
            ZStack {
                SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
                    .ignoresSafeArea(edges: fullScreen ? .all : .bottom)
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
                        Button("Keyboard", systemImage: "keyboard") { feed.toggleKeyboard() }.labelStyle(.iconOnly)
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Keyboard", systemImage: "keyboard") { feed.toggleKeyboard() }
                }
            }
        }
        .task { await follow() }
        .onDisappear { channel?.cancel() }
    }

    private func follow() async {
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await chats.openSurface(attachment, in: agent)
            self.channel = channel
            defer { channel.cancel() }
            for try await frame in channel.frames {
                switch LinkSurface.message(frame) {
                case .packets(let packets)?: feed.receive(packets)
                case .failed(let reason)?: failure = reason; showing = false
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
}
