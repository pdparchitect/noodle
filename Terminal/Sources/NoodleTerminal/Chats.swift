import AppKit
import Foundation
import HubLink
import SwiftTUICLI
import TerminalCore

enum Focus: Hashable {
    case search, list, messages, composer
}

/// The bots and groups of the space on the left, the one chosen on the right.
struct SplitView: View {
    let hubs: TerminalHubs
    let app: AppState
    @State private var selection: TerminalHubs.Row.Key?
    @FocusState private var focus: Focus?
    /// Where the keys go once the palette closes: back where they were, or where a command sends them.
    @State private var afterPalette: Focus?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(hubs: hubs, app: app, selection: $selection, focus: $focus, typing: startTyping)
                .frame(width: 40)
            if let row = hubs.row(selection) {
                ConversationView(row: row, hubs: hubs, app: app, state: app.conversation(row.id), focus: $focus, leave: { focus = .list },
                                 typing: startTyping)
                    .id(row.id)
            } else {
                Text(hubs.isLoaded ? "Choose a bot or group. Control-K shows everything you can do." : "Connecting…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Tab goes between the four places to be, never through each message; Up and Down move between those.
        .onKeyPress(.tab) { _ in cycleFocus(1) }
        .onKeyPress(.tab, modifiers: .shift) { _ in cycleFocus(-1) }
        .overlay(alignment: .top) {
            if app.showsPalette { CommandPalette(entries: entries, close: { app.showsPalette = false }) }
        }
        .panel(id: "conversations")
        .keyCommand("Commands", key: .character("k"), modifiers: .ctrl) {
            afterPalette = focus
            app.showsPalette = true
        }
        .keyCommand("Search", key: .character("f"), modifiers: .ctrl) { focus = .search }
        .keyCommand("Conversations", key: .character("l"), modifiers: .ctrl) { focus = .list }
        .keyCommand("Join Another Hub", key: .character("n"), modifiers: .ctrl) { app.push(.join) }
        .keyCommand("Next Space", key: .character("o"), modifiers: .ctrl) { nextSpace() }
        .onChange(of: selection) { _, chosen in
            if let row = hubs.row(chosen) { row.chats.shownConversation = row.thread.conversationID }
        }
        .onChange(of: app.showsPalette) { _, shown in
            if !shown { focus = afterPalette ?? .list }
        }
        .onChange(of: hubs.space) { _, _ in
            if let selection, !hubs.rows.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    private func cycleFocus(_ step: Int) -> KeyPressResult {
        guard !app.showsPalette else { return .ignored }
        var places: [Focus] = [.search, .list]
        if let row = hubs.row(selection) {
            places.append(.messages)
            if row.chats.composerUnavailableReason(for: row.thread) == nil { places.append(.composer) }
        }
        let index = focus.flatMap { places.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        focus = places[(index + step + places.count) % places.count]
        return .handled
    }

    /// A letter or digit typed in the list or the messages goes to the chosen conversation's message field, as the
    /// start of a message, so writing never needs a key to get there first.
    private func startTyping(_ press: KeyPress) -> KeyPressResult {
        guard press.modifiers.isEmpty || press.modifiers == .shift, case .character(let character) = press.key,
              character.isLetter || character.isNumber, let row = hubs.row(selection),
              row.chats.composerUnavailableReason(for: row.thread) == nil else { return .ignored }
        let state = app.conversation(row.id)
        state.attaching = false
        state.draft += String(character)
        focus = .composer
        return .handled
    }

    private func nextSpace() {
        let spaces = hubs.spaces
        guard let index = spaces.firstIndex(of: hubs.space) else { return }
        hubs.space = spaces[(index + 1) % spaces.count]
    }

    // MARK: Commands

    private var entries: [PaletteEntry] {
        var entries: [PaletteEntry] = []
        if let row = hubs.row(selection) {
            entries += threadEntries(row)
            let state = app.conversation(row.id)
            if let id = state.message, let message = row.chats.messages(of: row.thread).first(where: { $0.id == id }) {
                entries += messageEntries(message, in: row)
            }
        }
        do {
            entries += hubs.spaces.filter { $0 != hubs.space }.map { space in
                PaletteEntry("Show \(hubs.name(of: space))", space == .all ? "Every Hub's bots and groups" : "Only this Hub's bots and groups") {
                    hubs.space = space
                }
            }
        }
        entries += [
            PaletteEntry("New Bot…") { app.push(.newBot) },
            PaletteEntry("New Group…") { app.push(.newGroup) },
            PaletteEntry("Archived…", "Bots and groups you archived") { app.push(.archived) },
            PaletteEntry("Hubs…", "Your Hubs, pairing devices, users, leaving") { app.push(.hubs) },
            PaletteEntry("Join Another Hub…") { app.push(.join) },
            PaletteEntry("Search", "Control-F") { afterPalette = .search },
        ]
        return entries
    }

    private func threadEntries(_ row: TerminalHubs.Row) -> [PaletteEntry] {
        let chats = row.chats, thread = row.thread, name = thread.name, app = app
        var entries: [PaletteEntry] = []
        if chats.composerUnavailableReason(for: thread) == nil {
            entries.append(PaletteEntry("Attach File…", "Send a file from this Mac to \(name)") {
                app.conversation(row.id).attaching = true
                afterPalette = .composer
            })
        }
        if chats.hasEarlier(thread) {
            entries.append(PaletteEntry("Load Earlier Messages") { app.run { try await chats.loadEarlier(thread) } })
        }
        entries.append(thread.pinnedAt == nil
            ? PaletteEntry("Pin \(name)", "Keep it at the top on all your devices") { app.run { try await chats.setPinned(true, thread) } }
            : PaletteEntry("Unpin \(name)") { app.run { try await chats.setPinned(false, thread) } })
        switch thread {
        case .bot(let bot) where bot.owner != nil:
            break
        case .bot(let bot):
            entries += [
                PaletteEntry("Edit \(name)…", "Name, description, backstory, harness, model and picture") { app.push(.editBot(row.id)) },
                PaletteEntry("Tools for \(name)…") { app.push(.tools(row.id, .connection)) },
                PaletteEntry("Computers for \(name)…") { app.push(.tools(row.id, .computer)) },
                PaletteEntry("Browsers for \(name)…") { app.push(.tools(row.id, .browser)) },
            ]
            if chats.canShareBots {
                entries.append(PaletteEntry("Share \(name)…", "Choose who else on the Hub can talk to it") { app.push(.sharing(row.id)) })
            }
            if bot.phase == .ready {
                entries.append(PaletteEntry("Organize \(name)", "Tidy its workspace and memory") {
                    app.run {
                        try await chats.organize(bot)
                        app.tell("\(name) is organizing.")
                    }
                })
            }
            if bot.phase == .failed || bot.pause?.kickable == true {
                entries.append(PaletteEntry("Kick \(name)", "Start it again") { kick(bot, in: chats) })
            }
            entries.append(PaletteEntry("New Session for \(name)…", "A fresh context; workspace, memory and messages are kept") {
                app.confirming = Confirmation(title: "Start a new session for \(name)?",
                    message: "\(name) will start with a fresh context. Its workspace, memory and messages are kept.",
                    button: "New Session") { try await chats.startNewSession(bot) }
            })
            entries.append(PaletteEntry("Delete \(name)…") {
                app.confirming = Confirmation(title: "Delete \(name)?",
                    message: "The bot and its conversation are deleted from the Hub for all your devices.", button: "Delete") {
                    try await chats.delete(bot)
                }
            })
        case .group(let group):
            entries.append(PaletteEntry("Edit \(name)…", "Name, description and bots") { app.push(.editGroup(row.id)) })
            if chats.mutesGroups {
                let current = chats.chosenNotifications(of: group)
                let levels: [(LinkNotifications, String)] = [(.default, "As All Groups"), (.all, "All Messages")]
                    + (chats.notifiesMentions ? [(.mentions, "Mentions Only")] : []) + [(.muted, "Muted")]
                for (level, title) in levels where level != (current ?? .default) {
                    entries.append(PaletteEntry("Notify for \(name): \(title)") {
                        app.run { try await chats.setNotifications(level, of: group) }
                    })
                }
            }
            entries.append(PaletteEntry("Delete \(name)…") {
                app.confirming = Confirmation(title: "Delete \(name)?",
                    message: "The group and its conversation are deleted from the Hub for all your devices. Its bots are kept.",
                    button: "Delete") { try await chats.deleteGroup(group) }
            })
        }
        entries.append(PaletteEntry("Archive \(name)", "It keeps everything but leaves the list on all your devices") {
            app.run {
                try await chats.setArchived(true, thread)
                app.tell("\(name) is archived. Bring it back from Archived in the palette.")
            }
        })
        return entries
    }

    private func kick(_ bot: LinkBot, in chats: HubChats) {
        let app = app
        app.run {
            guard let confirmation = try await chats.kick(bot) else { return app.tell("\(bot.draft.name) is starting again.") }
            app.confirming = Confirmation(title: confirmation.title, message: confirmation.message, button: confirmation.confirmTitle) {
                try await chats.confirmKick(confirmation, for: bot)
            }
        }
    }

    static let reactions = ["👍", "❤️", "😂", "🎉", "👀", "❓"]

    private func messageEntries(_ message: LinkMessage, in row: TerminalHubs.Row) -> [PaletteEntry] {
        let chats = row.chats, app = app
        var entries: [PaletteEntry] = []
        if chats.canTryAgain(message) {
            entries.append(PaletteEntry("Try Sending Again") { Task { await chats.tryAgain(message) } })
        }
        if chats.unsent[message.id] != nil, !chats.sending.contains(message.id) {
            entries.append(PaletteEntry("Delete Undelivered Message") { chats.deleteUnsent(message) })
        }
        for attachment in message.attachments {
            if let url = attachment.url {
                if ["http", "https"].contains(url.scheme?.lowercased()) {
                    entries.append(PaletteEntry("Open Link \(url.host() ?? url.absoluteString)") { NSWorkspace.shared.open(url) })
                }
                continue
            }
            entries.append(PaletteEntry("Open \(attachment.filename)", "Download it and open it on this Mac") {
                app.run {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Noodle Terminal/\(message.id)", isDirectory: true)
                    NSWorkspace.shared.open(try await chats.download(attachment, of: message, into: folder))
                }
            })
            entries.append(PaletteEntry("Save \(attachment.filename) to Downloads") {
                app.run {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    let saved = try await chats.download(attachment, of: message, into: downloads)
                    app.tell("Saved to \(saved.path(percentEncoded: false))")
                }
            })
        }
        for url in Markdown.links(in: message.body) {
            entries.append(PaletteEntry("Open Link \(url.host() ?? url.absoluteString)", url.absoluteString) { NSWorkspace.shared.open(url) })
        }
        if !message.body.isEmpty {
            entries.append(PaletteEntry("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body, forType: .string)
                app.tell("Copied.")
            })
        }
        if chats.unsent[message.id] == nil {
            for emoji in Self.reactions {
                let mine = message.reactions.contains(LinkReaction(author: .you, emoji: emoji))
                entries.append(PaletteEntry(mine ? "Take Back \(emoji)" : "React \(emoji)") {
                    app.run { try await chats.toggleReaction(emoji, on: message) }
                })
            }
        }
        return entries
    }
}

/// The space, the search field, and the list it narrows: bots and groups by name, then the messages that say the term.
struct Sidebar: View {
    let hubs: TerminalHubs
    let app: AppState
    @Binding var selection: TerminalHubs.Row.Key?
    var focus: FocusState<Focus?>.Binding
    let typing: @MainActor @Sendable (KeyPress) -> KeyPressResult
    @State private var searchText = ""
    @State private var messageMatches: [TerminalHubs.MessageMatch] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search", text: $searchText)
                .focused(focus, equals: .search)
                .onSubmit { focus.wrappedValue = .list }
            if let search = ConversationSearch(searchText) {
                results(search)
            } else {
                List(hubs.rows, selection: $selection) { row in
                    ConversationRow(row: row, showsHub: hubs.shownChats.count > 1)
                }
                .listStyle(CompactListStyle())
                .focusable(true)
                .focused(focus, equals: .list)
                .box(focused: focus.wrappedValue == .list, filling: true)
                .onKeyPress(.return) { _ in
                    focus.wrappedValue = .composer
                    return .handled
                }
                .onKeyPress(perform: typing)
            }
            ForEach(hubs.shownChats.filter { !$0.isConnected && $0.error != nil }) { problem in
                Divider()
                Text("\(problem.hubName): \(problem.error ?? "")").foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 1)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: searchText) {
            messageMatches = []
            guard let search = ConversationSearch(searchText) else { return }
            // Typing on: only the term the person stopped at is searched.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await hubs.messages(matching: search)
            if !Task.isCancelled { messageMatches = found }
        }
    }

    private func results(_ search: ConversationSearch) -> some View {
        let rows = hubs.rows(matching: search)
        return List(selection: $selection) {
            if !rows.isEmpty {
                Section("Bots and Groups") {
                    ForEach(rows) { row in
                        ConversationRow(row: row, showsHub: hubs.shownChats.count > 1).tag(Optional(row.id))
                    }
                }
            }
            if !messageMatches.isEmpty {
                Section("Messages") {
                    ForEach(messageMatches) { found in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(found.row.thread.name).bold()
                            Text(found.match.snippet).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(Optional(found.row.id))
                    }
                }
            }
            if rows.isEmpty && messageMatches.isEmpty {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        .listStyle(CompactListStyle())
        .focusable(true)
        .focused(focus, equals: .list)
        .box(focused: focus.wrappedValue == .list, filling: true)
        .onKeyPress(.return) { _ in
            focus.wrappedValue = .composer
            return .handled
        }
        .onKeyPress(perform: typing)
    }
}

/// A bot's or group's picture and name with a dot while unread, and its latest message under it.
struct ConversationRow: View {
    let row: TerminalHubs.Row
    let showsHub: Bool

    var body: some View {
        let chats = row.chats, thread = row.thread
        let unread = chats.isUnread(thread)
        HStack(alignment: .top, spacing: 1) {
            // A square slot of two lines; the picture is drawn smaller inside it, as a narrower slot would stretch it.
            Image(data: Pictures.png(for: thread, in: chats, scale: 0.75)).resizable().scaledToFit().frame(width: 4, height: 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 1) {
                    if unread { Text("●").foregroundStyle(chats.countsAsUnread(thread) ? .tint : .secondary) }
                    Text(thread.name).bold(unread).lineLimit(1)
                    if thread.pinnedAt != nil { Text("📌") }
                    Spacer()
                    if showsHub { Text(chats.hubName).foregroundStyle(.secondary).lineLimit(1) }
                }
                Text(line(chats, thread)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func line(_ chats: HubChats, _ thread: HubThread) -> String {
        if let pause = thread.bot?.pause { return pause.shown() }
        return ConversationRowDetail.standard.line(
            isGroup: thread.group != nil, description: thread.about, status: thread.bot?.status,
            latestReply: { chats.messages(of: thread).last { if case .bot = $0.author { true } else { false } }.map { Markdown.plain($0.body) } },
            latestMessage: chats.messages(of: thread).last { $0.author != .system }.map { Markdown.plain($0.body) } ?? thread.about)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The space shown, which opens the list of spaces to choose another: All, or one Hub's bots and groups.
struct SpaceMenu: View {
    let hubs: TerminalHubs
    var title: String?

    var body: some View {
        Menu {
            Text(title ?? hubs.name(of: hubs.space)).bold()
        } content: {
            ForEach(hubs.spaces, id: \.self) { space in
                Button((space == hubs.space ? "✓ " : "  ") + hubs.name(of: space)) { hubs.space = space }
            }
        }
        // Clicked, or Control-O; Tab goes between the boxes, not to it.
        .focusable(false)
    }
}

/// Rows one after another, without lines between them or a frame of the list's own: the box around it shows focus.
struct CompactListStyle: ListStyle {
    var snapshotLabel: String { "CompactListStyle" }

    @MainActor func resolvePresentation(for configuration: ListStyleConfiguration) -> ListStylePresentation {
        var presentation = ListStylePresentation.plain
        presentation.showsRowSeparators = false
        presentation.showsSectionSeparators = false
        return presentation
    }
}
