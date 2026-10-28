import AuthenticationServices
import HubLink
import SwiftUI
import UniformTypeIdentifiers

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
        if connections != listed { connections = listed }
    }

    func loadComputers() async throws {
        guard case .computers(let listed) = try await pairing.request(.computers) else { throw LinkError("The Hub sent an unexpected answer.") }
        if computers != listed { computers = listed }
    }

    func loadBrowsers() async throws {
        guard case .browsers(let listed) = try await pairing.request(.browsers) else { throw LinkError("The Hub sent an unexpected answer.") }
        if browsers != listed { browsers = listed }
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

    /// Renames and describes a computer; an empty description clears it.
    func updateComputer(_ computer: LinkComputer, name: String, description: String) async throws {
        _ = try await pairing.request(.updateComputer(id: computer.id, LinkComputerDraft(name: name, description: description)))
        try await loadComputers()
    }

    func deleteComputer(_ computer: LinkComputer) async throws {
        _ = try await pairing.request(.deleteComputer(id: computer.id))
        try await loadComputers()
    }

    func createBrowser(named name: String) async throws {
        _ = try await pairing.request(.createBrowser(LinkBrowserDraft(name: name)))
        try await loadBrowsers()
    }

    /// Renames and describes a browser; an empty description clears it.
    func updateBrowser(_ browser: LinkBrowser, name: String, description: String) async throws {
        _ = try await pairing.request(.updateBrowser(id: browser.id, LinkBrowserDraft(name: name, description: description)))
        try await loadBrowsers()
    }

    func deleteBrowser(_ browser: LinkBrowser) async throws {
        _ = try await pairing.request(.deleteBrowser(id: browser.id))
        try await loadBrowsers()
    }

    /// What deleting one of this user's connections, computers or browsers does, naming the bots that lose it.
    func deletionSummary(_ kind: HubTool, _ id: UUID) -> String {
        func bots(_ ids: [UUID]?) -> [String] { (ids ?? []).compactMap { agent($0)?.name } }
        return switch kind {
        case .connection: LinkConnection.deletionSummary(bots: bots(connections.first { $0.id == id }?.botIDs))
        case .computer: LinkComputer.deletionSummary(bots: bots(computers.first { $0.id == id }?.botIDs))
        case .browser: LinkBrowser.deletionSummary(bots: bots(browsers.first { $0.id == id }?.botIDs))
        }
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

    /// Lets a bot make images with the Hub's image model, or stops it, on the bot as the Hub has it.
    func setImageGeneration(_ on: Bool, for agent: LinkBot) async throws {
        guard var bot = self.agent(agent.id) else { throw LinkError("The bot is no longer on the Hub.") }
        bot.draft.imageGeneration = on
        try await update(bot)
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
        if let known = knownCards.object(forKey: attachment.id as NSUUID), known.isFresh {
            var resolved = attachment
            resolved.card = known.card
            return resolved
        }
        let pairing = pairing
        var resolved = await attachment.resolvingCard(in: conversation.conversationID) { try await pairing.request($0) }
        if resolved.card?.image == nil, let image = try? await picture(for: attachment, in: conversation) {
            if resolved.card == nil { resolved.card = LinkCardInfo(title: attachment.liveTitle) }
            resolved.card?.image = image
        }
        if let card = resolved.card {
            remember(KnownCard(card, isFresh: true), for: attachment)
            keep(card, for: attachment)
        }
        return resolved
    }

    /// The card as this phone last had it, kept across launches, so its picture shows at once while it
    /// is asked for again.
    func keptCard(for attachment: LinkAttachment) -> LinkCardInfo? {
        if let known = knownCards.object(forKey: attachment.id as NSUUID) { return known.card }
        let card = (try? Data(contentsOf: cardURL(for: attachment))).flatMap { try? JSONDecoder().decode(LinkCardInfo.self, from: $0) }
        remember(KnownCard(card, isFresh: false), for: attachment)
        return card
    }

    private func remember(_ known: KnownCard, for attachment: LinkAttachment) {
        knownCards.setObject(known, forKey: attachment.id as NSUUID, cost: (known.card?.image?.count ?? 0) + (known.card?.icon?.count ?? 0))
    }

    /// Where this Hub's noodlets are kept on this phone.
    var noodletCache: URL { DownloadedNoodlet.root.appendingPathComponent(pairing.directory.lastPathComponent) }

    /// The latest picture of what a link points at, for a card that carries none, as a noodlet's.
    func picture(for attachment: LinkAttachment, in conversation: some HubConversation) async throws -> Data? {
        guard case .picture(let data) = try await pairing.request(.linkPreview(conversationID: conversation.conversationID, attachmentID: attachment.id))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        return data
    }
}

/// A shared card as this phone knows it: asked of the Hub this launch, or read back from what was kept.
final class KnownCard {
    let card: LinkCardInfo?
    let isFresh: Bool

    init(_ card: LinkCardInfo?, isFresh: Bool) {
        self.card = card
        self.isFresh = isFresh
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
    /// Among the tools, as on the Mac: kept in the bot editor's copy too, so its Save does not undo it.
    var imageGeneration: Binding<Bool>? = nil
    @State private var adding = false
    @State private var busy: UUID?
    @State private var settingImageGeneration = false
    @State private var problem: String?
    /// The row whose Delete waits for confirmation.
    @State private var deleting: UUID?

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
            if let imageGeneration {
                imageGenerationRow(imageGeneration)
            } else if rows.isEmpty {
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
                    Button("Delete", role: .destructive) { deleting = row.id }
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
            NewHubToolSheet(chats: chats, agent: agent, kind: kind).formSheetSizing()
        }
        .confirmationDialog("Delete “\(rows.first(where: { $0.id == deleting })?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { id in
            Button("Delete", role: .destructive) { run(id) { try await delete(id) } }
        } message: { id in
            Text(chats.deletionSummary(kind, id))
        }
        .wordmarkRefreshable { try? await chats.loadTools() }
    }

    private func imageGenerationRow(_ on: Binding<Bool>) -> some View {
        Button {
            settingImageGeneration = true
            problem = nil
            Task {
                defer { settingImageGeneration = false }
                do {
                    try await chats.setImageGeneration(!on.wrappedValue, for: agent)
                    on.wrappedValue.toggle()
                } catch { problem = error.localizedDescription }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image Generation").foregroundStyle(.primary)
                    Text(chats.pairing.status?.imageModel ?? "No model on the Hub yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settingImageGeneration { ProgressView() }
                else if on.wrappedValue { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .disabled(settingImageGeneration)
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

/// One of this user's computers or browsers on the Hub, as its list and editor show it.
struct HubCompanion: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    /// Under its name: its description, or else what it is doing.
    let detail: String?

    init(_ computer: LinkComputer) {
        id = computer.id
        name = computer.name
        description = computer.description
        detail = computer.description ?? computer.state
    }

    init(_ browser: LinkBrowser) {
        id = browser.id
        name = browser.name
        description = browser.description
        detail = browser.description ?? (browser.paused ? "Paused" : nil)
    }
}

/// All of this user's computers or browsers on the Hub, whichever bots have them: tap one to rename
/// or describe it, swipe to delete it.
struct HubCompanionsScreen: View {
    let chats: HubChats
    let kind: HubTool
    @State private var editing: HubCompanion?
    @State private var deleting: HubCompanion?
    @State private var busy: UUID?
    @State private var problem: String?

    private var items: [HubCompanion] {
        kind == .computer ? chats.computers.map { HubCompanion($0) } : chats.browsers.map { HubCompanion($0) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("None on this Hub yet").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button { editing = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).foregroundStyle(.primary)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if busy == item.id { ProgressView() }
                    }
                }
                .disabled(busy == item.id)
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = item }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .navigationTitle(kind == .computer ? "Computers" : "Browsers")
        .sheet(item: $editing) { HubCompanionEditor(chats: chats, kind: kind, item: $0).formSheetSizing() }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete", role: .destructive) { delete(item) }
        } message: { item in
            Text(chats.deletionSummary(kind, item.id))
        }
        .wordmarkRefreshable { try? await load() }
    }

    private func load() async throws {
        if kind == .computer { try await chats.loadComputers() } else { try await chats.loadBrowsers() }
    }

    private func delete(_ item: HubCompanion) {
        busy = item.id
        problem = nil
        Task {
            defer { busy = nil }
            do {
                if kind == .computer, let computer = chats.computers.first(where: { $0.id == item.id }) {
                    try await chats.deleteComputer(computer)
                } else if let browser = chats.browsers.first(where: { $0.id == item.id }) {
                    try await chats.deleteBrowser(browser)
                }
            } catch { problem = error.localizedDescription }
        }
    }
}

/// A computer's or browser's name and description, saved on the Hub.
private struct HubCompanionEditor: View {
    let chats: HubChats
    let kind: HubTool
    let item: HubCompanion
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var saving = false
    @State private var problem: String?

    init(chats: HubChats, kind: HubTool, item: HubCompanion) {
        self.chats = chats
        self.kind = kind
        self.item = item
        _name = State(initialValue: item.name)
        _description = State(initialValue: item.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(kind == .computer ? "Edit Computer" : "Edit Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        saving = true
        problem = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                if kind == .computer {
                    guard let computer = chats.computers.first(where: { $0.id == item.id }) else { throw LinkError("The computer is no longer on the Hub.") }
                    try await chats.updateComputer(computer, name: name, description: description)
                } else {
                    guard let browser = chats.browsers.first(where: { $0.id == item.id }) else { throw LinkError("The browser is no longer on the Hub.") }
                    try await chats.updateBrowser(browser, name: name, description: description)
                }
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}

/// The other people on the Hub, each tapped to share one of this user's bots with them or stop. It
/// applies at once, on the Hub. With `hub`, a bot on the owner's own Mac and the people on that Hub the Mac joined.
struct BotSharingScreen: View {
    let chats: HubChats
    let agent: LinkBot
    var hub: String? = nil
    @State private var people: [LinkPerson]?
    @State private var shared: LinkHubSharing?
    @State private var busy: UUID?
    @State private var problem: String?

    private var sharedWith: [UUID] { hub == nil ? chats.agent(agent.id)?.sharedWith ?? agent.sharedWith : shared?.sharedWith ?? [] }

    var body: some View {
        List {
            if let people, people.isEmpty {
                Text("Nobody else is on this Hub").foregroundStyle(.secondary)
            } else if let people {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 14) {
                        ForEach(people) { person($0) }
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text(LinkPerson.sharingSummary(bot: chats.agent(agent.id)?.name ?? agent.name,
                                                   people: people.filter { sharedWith.contains($0.id) }.map(\.name)))
                        .contentTransition(.opacity)
                }
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .navigationTitle(shared?.name ?? "Sharing")
        .sensoryFeedback(.selection, trigger: sharedWith)
        .task {
            guard let hub else {
                do { people = try await chats.people() } catch { problem = error.localizedDescription }
                return
            }
            shared = await chats.hubSharing(agent).first { $0.id == hub }
            if let shared { people = shared.people } else { problem = "Your Mac cannot reach this Hub right now." }
        }
    }

    private func person(_ person: LinkPerson) -> some View {
        let selected = sharedWith.contains(person.id)
        return Button {
            busy = person.id
            problem = nil
            Task {
                defer { busy = nil }
                do {
                    if let hub, let current = shared {
                        shared = try await chats.toggleSharing(agent, with: person.id, on: current).first { $0.id == hub }
                    } else {
                        try await chats.toggleSharing(agent, with: person.id)
                    }
                } catch { problem = error.localizedDescription }
            }
        } label: {
            VStack(spacing: 6) {
                PersonAvatar(name: person.name, avatar: person.avatar, id: person.id, size: 56)
                    .padding(3)
                    .overlay { Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5) }
                    .overlay(alignment: .bottomTrailing) {
                        if busy == person.id {
                            ProgressView().controlSize(.small)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        } else if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 20))
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .opacity(selected ? 1 : 0.55)
                Text(person.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel(person.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working) }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
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
        if let data = preset.icon, let image = DecodedImages.picture(data) {
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
    @Environment(\.closeNoodlet) private var closeNoodlet
    @AppStorage(ScreenControlHaptics.key) private var haptics = false
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?
    /// The keys a game declared: shown as a controller in place of the keyboard.
    @State private var controls: Gamepad?
    @State private var notice: SurfaceNotice?
    @State private var showsControls = true
    @State private var hardware = HardwareGamepad()
    /// A game brought back from the TV to the phone.
    @State private var onPhone = false
    @State private var tvAvailable = false
    @State private var connectingTV = false
    @State private var gameMenu = GameMenu()
    /// The sign-in fields of the page shown, while the sheet for them is open.
    @State private var signInForm: LinkSignInForm?
    @State private var findingSignIn = false
    @State private var signInProblem: String?
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

    /// Back to where it was opened from: the conversation, or the console's shelves.
    private func close() { if let closeNoodlet { closeNoodlet() } else { dismiss() } }

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
        if attachment.liveKind == .browser, chats.signsInToBrowsers, showing {
            Button("Sign In…", systemImage: "key", action: findSignIn).disabled(findingSignIn)
        }
        if let runHere { Button("Run on \(UIDevice.current.model)", systemImage: ThisDevice.symbol(), action: runHere) }
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
                if let screenControls, showing { GamepadOverlay(gamepad: screenControls, haptics: haptics, onKey: hold) }
                if !onTV { GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu, onTV: false).ignoresSafeArea() }
                if !showing {
                    if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                    else { ProgressView().tint(.white) }
                }
            }
            .background(.black)
            // Under the buttons that float over the top corners of a full-screen view.
            .overlay(alignment: .topTrailing) { SurfaceNoticeView(showing && !onTV ? notice : nil).padding(.top, fullScreen ? 44 : 0) }
            .overlay(alignment: .top) {
                if fullScreen {
                    HStack {
                        Button("Done", action: close)
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
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                ToolbarItemGroup(placement: .primaryAction) { inputButtons }
            }
        }
        // The TV's view tells the Hub its size, so the game is drawn for the TV.
        .externalScreen(enabled: Binding(get: { controls != nil && !onPhone }, set: { onPhone = !$0 }), available: $tvAvailable) {
            SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
            GameMenuOverlay(gameMenu: gameMenu, menu: noodletMenu, onTV: true)
        }
        .tvConnectionAlert(isPresented: $connectingTV)
        .sheet(isPresented: Binding(get: { signInForm != nil }, set: { if !$0 { signInForm = nil } })) {
            if let form = signInForm {
                BrowserSignInSheet(form: form) { entry in
                    try await chats.fillSignIn(entry.fill(form, conversationID: thread.conversationID, attachmentID: attachment.id))
                }
            }
        }
        .alert("Can't Sign In", isPresented: Binding(get: { signInProblem != nil }, set: { if !$0 { signInProblem = nil } })) {
            Button("OK") {}
        } message: { Text(signInProblem ?? "") }
        .task { await follow() }
        // The phone turns sideways as a controller does.
        .onChange(of: onTV) {
            ScreenOrientation.hold(onTV ? .landscape : nil)
        }
        .onChange(of: NoodletPlayer.keepsAwake(onTV: onTV, controllerConnected: hardware.hasController), initial: true) { _, awake in
            KeepAwake.set(awake)
        }
        .onDisappear {
            hardware.detach(); channel?.cancel(); ScreenOrientation.hold(nil)
            KeepAwake.set(false)
        }
    }

    /// Asks the Hub, once, for the sign-in fields of the page shown.
    private func findSignIn() {
        findingSignIn = true
        Task {
            defer { findingSignIn = false }
            do { signInForm = try await chats.signInForm(attachment, in: thread) }
            catch { signInProblem = error.localizedDescription }
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
                gameMenu.follow(hardware: hardware, menu: { noodletMenu }, close: close)
            }
            for try await frame in channel.frames {
                switch LinkSurface.message(frame) {
                case .packets(let packets)?: feed.receive(packets)
                case .failed(let reason)?: failure = reason; showing = false
                case .controls(let gamepad)?:
                    controls = gamepad
                    hardware.attach(gamepad, onKey: hold)
                case .notice(let next)?: notice = next
                case .fileAsk(let ask)?:
                    for frame in await PhoneFilePicker.choose(ask) { channel.send(frame) }
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

    /// A picture, video or PDF, which the Hub shows a small picture of, so it need not come down to be seen.
    var hasHubPreview: Bool {
        voice == nil && (mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/") || mediaType == "application/pdf")
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


/// The document picker on the iPhone where the person is watching.
private final class PhoneFilePicker: NSObject, UIDocumentPickerDelegate {
    private var finish: (([URL]) -> Void)?

    static func choose(_ ask: SurfaceFileAsk) async -> [Data] {
        let urls = await PhoneFilePicker().present(ask)
        let picked = ask.multiple ? urls : Array(urls.prefix(1))
        return SurfaceFileRead.frames(id: ask.id, urls: picked)
    }

    private func present(_ ask: SurfaceFileAsk) async -> [URL] {
        let types: [UTType] = ask.directories ? [.item, .folder] : [.item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = ask.multiple
        picker.delegate = self
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return [] }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            top.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish?(urls); finish = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish?([]); finish = nil
    }

}
