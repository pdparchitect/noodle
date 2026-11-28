import Foundation
import HubLink
import TerminalCore
import TerminalScreen

/// The slash commands, and those that act on the conversation, its messages and the Hubs without a form.
extension App {
    func makeCommands() -> [Command] {
        let hasRow: @MainActor () -> Bool = { [unowned self] in row != nil }
        let hasMessages: @MainActor () -> Bool = { [unowned self] in row.map { !$0.chats.messages(of: $0.thread).isEmpty } ?? false }
        let ownBot: @MainActor () -> Bool = { [unowned self] in ownedBot != nil }
        let ownThread: @MainActor () -> Bool = { [unowned self] in row.map { $0.thread.bot?.owner == nil } ?? false }
        let isGroup: @MainActor () -> Bool = { [unowned self] in row?.thread.group != nil }
        return [
            Command(name: "switch", argument: "name", summary: "Go to a bot or group", fills: true, isAvailable: hasRow,
                    options: { [unowned self] in rows.map { Picker.Item(id: Self.itemID($0.id), label: $0.thread.name, detail: Self.kind(of: $0, among: hubs)) } }) {
                [unowned self] in switchTo($0)
            },
            Command(name: "bots", summary: "Choose a bot", isAvailable: { [unowned self] in rows.contains { $0.thread.bot != nil } }) {
                [unowned self] _ in showThreads("bots", groups: false)
            },
            Command(name: "groups", summary: "Choose a group", isAvailable: { [unowned self] in rows.contains { $0.thread.group != nil } }) {
                [unowned self] _ in showThreads("groups", groups: true)
            },
            Command(name: "search", argument: "text", summary: "Find bots, groups and messages", fills: true, isAvailable: { [unowned self] in !hubs.chats.isEmpty }) {
                [unowned self] in search($0)
            },
            Command(name: "earlier", summary: "Load earlier messages", isAvailable: { [unowned self] in row.map { $0.chats.hasEarlier($0.thread) } ?? false }) {
                [unowned self] _ in loadEarlier()
            },
            Command(name: "space", summary: "Show every Hub's bots and groups, or one Hub's", isAvailable: { [unowned self] in hubs.chats.count > 1 }) {
                [unowned self] _ in chooseSpace()
            },
            Command(name: "pin", summary: "Keep it at the top on all your devices", isAvailable: { [unowned self] in row.map { $0.thread.pinnedAt == nil } ?? false }) {
                [unowned self] _ in setPinned(true)
            },
            Command(name: "unpin", summary: "Take it off the top", isAvailable: { [unowned self] in row?.thread.pinnedAt != nil }) {
                [unowned self] _ in setPinned(false)
            },
            Command(name: "archive", summary: "Take it off the list on all your devices; it keeps everything", isAvailable: hasRow) {
                [unowned self] _ in archive()
            },
            Command(name: "archived", summary: "Bring back a bot or group you archived",
                    isAvailable: { [unowned self] in hubs.chats.contains { !$0.archivedThreads.isEmpty } }) {
                [unowned self] _ in showArchived()
            },
            Command(name: "notify", summary: "Choose how this group notifies you",
                    isAvailable: { [unowned self] in row.map { $0.thread.group != nil && $0.chats.mutesGroups } ?? false }) {
                [unowned self] _ in chooseNotifications()
            },
            Command(name: "copy", summary: "Copy the chosen message, or the newest", isAvailable: hasMessages) { [unowned self] _ in copyMessage() },
            Command(name: "react", argument: "emoji", summary: "React to the chosen message, or the newest", isAvailable: hasMessages,
                    options: { Self.reactions.map { Picker.Item(id: $0, label: $0) } }) {
                [unowned self] in react($0)
            },
            Command(name: "open", summary: "Open a link or file in the chosen message, or the newest", isAvailable: hasMessages) {
                [unowned self] _ in openFromMessage()
            },
            Command(name: "save", summary: "Save a file in the chosen message, or the newest, to Downloads", isAvailable: hasMessages) {
                [unowned self] _ in saveFromMessage()
            },
            Command(name: "retry", summary: "Try sending a message that wasn't delivered again",
                    isAvailable: { [unowned self] in row.map { row in row.chats.messages(of: row.thread).contains { row.chats.canTryAgain($0) } } ?? false }) {
                [unowned self] _ in retry()
            },
            Command(name: "discard", summary: "Delete a message that wasn't delivered",
                    isAvailable: { [unowned self] in row.map { row in row.chats.messages(of: row.thread).contains { Self.isDiscardable($0, in: row.chats) } } ?? false }) {
                [unowned self] _ in discard()
            },
            Command(name: "file", argument: "path", summary: "Send a file from \(Desktop.computer)", fills: true, isAvailable: hasRow) {
                [unowned self] in sendFile($0)
            },
            Command(name: "new", argument: "bot or group", summary: "Make a bot or group", isAvailable: { [unowned self] in !hubs.chats.isEmpty },
                    options: { [Picker.Item(id: "bot", label: "bot"), Picker.Item(id: "group", label: "group")] }) {
                [unowned self] in makeNew($0)
            },
            Command(name: "edit", summary: "Change its name and description, and a bot's backstory or a group's bots", isAvailable: ownThread) {
                [unowned self] _ in edit()
            },
            Command(name: "harness", summary: "Choose the bot's harness", isAvailable: ownBot) { [unowned self] _ in changeHarness() },
            Command(name: "model", summary: "Choose the bot's model", isAvailable: { [unowned self] in ownedBot.map { !models(for: $0.bot.draft, in: $0.row.chats).isEmpty } ?? false }) {
                [unowned self] _ in changeModel()
            },
            Command(name: "effort", summary: "Choose how hard the bot's model thinks", isAvailable: { [unowned self] in ownedBot.map { !efforts(for: $0.bot.draft, in: $0.row.chats).isEmpty } ?? false }) {
                [unowned self] _ in changeEffort()
            },
            Command(name: "colour", summary: "Choose the bot's colour", isAvailable: ownBot) { [unowned self] _ in changeColour() },
            Command(name: "symbol", argument: "name", summary: "Choose the bot's symbol, such as sparkles", isAvailable: ownBot) {
                [unowned self] in changeSymbol($0)
            },
            Command(name: "members", summary: "Choose the group's bots", isAvailable: isGroup) { [unowned self] _ in changeMembers() },
            Command(name: "tools", summary: "Choose the tools the bot can use", isAvailable: ownBot) { [unowned self] _ in chooseTools(.connection) },
            Command(name: "computers", summary: "Choose the computers the bot can use", isAvailable: ownBot) { [unowned self] _ in chooseTools(.computer) },
            Command(name: "browsers", summary: "Choose the browsers the bot can use", isAvailable: ownBot) { [unowned self] _ in chooseTools(.browser) },
            Command(name: "share", summary: "Choose who else on the Hub can talk to the bot",
                    isAvailable: { [unowned self] in ownedBot?.row.chats.canShareBots == true }) {
                [unowned self] _ in share()
            },
            Command(name: "session", summary: "Start the bot on a fresh context; its workspace, memory and messages are kept", isAvailable: ownBot) {
                [unowned self] _ in newSession()
            },
            Command(name: "organize", summary: "Ask the bot to tidy its workspace and memory",
                    isAvailable: { [unowned self] in ownedBot?.bot.phase == .ready }) {
                [unowned self] _ in organize()
            },
            Command(name: "kick", summary: "Start the bot again",
                    isAvailable: { [unowned self] in ownedBot.map { $0.bot.phase == .failed || $0.bot.pause?.kickable == true } ?? false }) {
                [unowned self] _ in kick()
            },
            Command(name: "delete", summary: "Delete it from the Hub for all your devices", isAvailable: ownThread) { [unowned self] _ in delete() },
            Command(name: "join", argument: "link", summary: "Join a Hub with an invitation link or code", fills: true) { [unowned self] in join($0) },
            Command(name: "hubs", summary: "Your Hubs: whether they're connected, how groups notify you, leaving",
                    isAvailable: { [unowned self] in !hubs.chats.isEmpty }) {
                [unowned self] _ in showHubs()
            },
            Command(name: "pair", summary: "Invite another of your devices",
                    isAvailable: { [unowned self] in hubs.chats.contains { $0.pairing.status?.canPairDevices == true } }) {
                [unowned self] _ in pairDevice()
            },
            Command(name: "users", summary: "Manage the people on your Hub",
                    isAvailable: { [unowned self] in hubs.chats.contains { $0.pairing.status?.isAdmin == true } }) {
                [unowned self] _ in manageUsers()
            },
            Command(name: "help", summary: "Show the commands") { [unowned self] _ in showHelp() },
            Command(name: "quit", summary: "Leave Noodle") { [unowned self] _ in quit() },
        ]
    }

    /// Why a command does nothing where it was typed.
    static func unavailable(_ name: String) -> String {
        switch name {
        case "switch", "bots", "groups", "archive": "There are no bots or groups yet: /new bot"
        case "search", "new", "hubs": "Join a Hub first: paste an invitation link or code."
        case "earlier": "All the messages are shown."
        case "space": "You have one Hub; /join adds another."
        case "pin": "It's pinned already."
        case "unpin": "It isn't pinned."
        case "archived": "Nothing is archived."
        case "notify", "members": "/\(name) is for groups."
        case "copy", "react", "open", "save": "There are no messages yet."
        case "retry": "Only the newest message, if it wasn't delivered, can be sent again."
        case "discard": "Only a message that wasn't delivered can be deleted here."
        case "file": "Nothing can be sent here."
        case "model": "Its harness offers no choice of model."
        case "effort": "Its model offers no choice of effort."
        case "share": "Only your own bots can be shared, where your plan allows it."
        case "organize": "Only a ready bot can organize."
        case "kick": "Only a bot that stopped or waits for a kick can be kicked."
        case "pair": "Your Hub doesn't let you pair devices."
        case "users": "Only a Hub's admins manage its users."
        default: "Only your own bots and groups can be changed."
        }
    }

    static let reactions = ["👍", "❤️", "😂", "🎉", "👀", "❓"]

    /// A row's key as a list item's ID.
    static func itemID(_ key: TerminalHubs.Row.Key) -> String { "\(UInt(bitPattern: key.hub.hashValue))/\(key.thread)" }

    /// The bot on screen, when it is the person's own to change.
    var ownedBot: (row: TerminalHubs.Row, bot: LinkBot)? {
        guard let row, let bot = row.thread.bot, bot.owner == nil else { return nil }
        return (row, bot)
    }

    // MARK: Conversations

    private func switchTo(_ name: String) {
        if name.isEmpty { return showThreads("bots and groups", groups: nil) }
        if let match = bestMatch(name) { open(match) } else { tell("No bot or group is called \(name).") }
    }

    /// What a list says about a bot or group: unread, pinned, when it last moved, its Hub, and what it is.
    private func detail(of row: TerminalHubs.Row) -> String {
        let chats = row.chats, thread = row.thread
        return [chats.countsAsUnread(thread) ? "unread" : nil, thread.pinnedAt != nil ? "pinned" : nil,
                SidebarTimestamp.text(for: chats.recency(of: thread)), hubs.chats.count > 1 ? chats.hubName : nil,
                thread.about.isEmpty ? nil : thread.about]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func showThreads(_ title: String, groups: Bool?) {
        Task {
            let result = await pick(Picker(title: title, items: { [self] in
                rows.filter { groups == nil || ($0.thread.group != nil) == groups }.map { row in
                    Picker.Item(id: Self.itemID(row.id), label: row.thread.name, detail: detail(of: row), current: row.id == current)
                }
            }))
            guard case .chose(let item) = result, let row = rows.first(where: { Self.itemID($0.id) == item.id }) else { return }
            open(row)
        }
    }

    private func search(_ text: String) {
        guard let search = ConversationSearch(text) else { return tell("Type what to find after /search.") }
        found = nil
        Task {
            let messages = await hubs.messages(matching: search)
            found = messages
            scheduleRedraw()
        }
        Task {
            let result = await pick(Picker(title: "results", items: { [self] in
                let threads = hubs.rows(matching: search).map { row in
                    Picker.Item(id: "row " + Self.itemID(row.id), label: row.thread.name, detail: Self.kind(of: row, among: hubs))
                }
                guard let found else { return threads + [Picker.Item(id: "searching", label: "Messages", detail: "Searching…")] }
                return threads + found.map { match in
                    Picker.Item(id: "message \(match.id)", label: match.row.thread.name,
                                detail: SidebarTimestamp.text(for: match.match.createdAt) + " · " + match.match.snippet)
                }
            }))
            guard case .chose(let item) = result else { return }
            if let row = hubs.rows(matching: search).first(where: { "row " + Self.itemID($0.id) == item.id }) { return open(row) }
            if let match = found?.first(where: { "message \($0.id)" == item.id }) { await show(match) }
        }
    }

    /// Opens the conversation a message found is in, loading earlier messages until it is there, and chooses it.
    private func show(_ found: TerminalHubs.MessageMatch) async {
        open(found.row)
        let chats = found.row.chats, thread = found.row.thread, id = found.match.messageID
        var pages = 0
        while !chats.messages(of: thread).contains(where: { $0.id == id }), chats.hasEarlier(thread), pages < 20 {
            do { try await chats.loadEarlier(thread) } catch { return tell(error.localizedDescription) }
            pages += 1
        }
        if chats.messages(of: thread).contains(where: { $0.id == id }) {
            selected = id
        } else {
            tell("That message is too far back to show here.")
        }
    }

    private func loadEarlier() {
        guard let row else { return }
        perform { try await row.chats.loadEarlier(row.thread) }
    }

    private func chooseSpace() {
        Task {
            let spaces = hubs.spaces
            guard let item = await choose("spaces", { [self] in
                spaces.enumerated().map { index, space in
                    Picker.Item(id: "\(index)", label: hubs.name(of: space),
                                detail: space == .all ? "Every Hub's bots and groups" : "Only this Hub's bots and groups", current: space == hubs.space)
                }
            }), let index = Int(item.id), spaces.indices.contains(index) else { return }
            hubs.space = spaces[index]
        }
    }

    private func setPinned(_ pinned: Bool) {
        guard let row else { return }
        perform {
            try await row.chats.setPinned(pinned, row.thread)
            self.tell(pinned ? "\(row.thread.name) is pinned." : "\(row.thread.name) is unpinned.")
        }
    }

    private func archive() {
        guard let row else { return }
        perform {
            try await row.chats.setArchived(true, row.thread)
            self.tell("\(row.thread.name) is archived. /archived brings it back.")
        }
    }

    private func showArchived() {
        Task {
            let archived: @MainActor () -> [TerminalHubs.Row] = { [self] in
                hubs.chats.flatMap { chats in chats.archivedThreads.map { TerminalHubs.Row(chats: chats, thread: $0) } }
            }
            guard let item = await choose("archived bots and groups", verb: "brings back", { [self] in
                archived().map { Picker.Item(id: Self.itemID($0.id), label: $0.thread.name, detail: Self.kind(of: $0, among: hubs)) }
            }), let row = archived().first(where: { Self.itemID($0.id) == item.id }) else { return }
            do {
                try await row.chats.setArchived(false, row.thread)
                if let restored = hubs.row(row.id) { open(restored) }
                tell("\(row.thread.name) is back.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    private static func notificationName(_ level: LinkNotifications) -> String {
        switch level {
        case .all: "All messages"
        case .mentions: "Mentions only"
        case .muted: "Muted"
        default: "As all groups"
        }
    }

    private func chooseNotifications() {
        guard let row, let group = row.thread.group else { return }
        let chats = row.chats
        Task {
            let levels: [LinkNotifications] = [.default, .all] + (chats.notifiesMentions ? [.mentions] : []) + [.muted]
            guard let item = await choose("how \(group.draft.name) notifies you", {
                let chosen = chats.chosenNotifications(of: group) ?? .default
                return levels.enumerated().map { index, level in
                    Picker.Item(id: "\(index)", label: Self.notificationName(level),
                                detail: level == .default ? "Now " + Self.notificationName(chats.pairing.status?.groupNotifications ?? .all).lowercased() : "",
                                current: level == chosen)
                }
            }), let index = Int(item.id) else { return }
            do {
                try await chats.setNotifications(levels[index], of: group)
                tell("\(group.draft.name) notifies you: \(Self.notificationName(levels[index]).lowercased()).")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    // MARK: Messages

    /// The message a command acts on: the one chosen, or else the newest that suits it, or the newest.
    private func target(_ suits: (LinkMessage) -> Bool = { _ in true }) -> (row: TerminalHubs.Row, message: LinkMessage)? {
        guard let row else { return nil }
        let messages = row.chats.messages(of: row.thread)
        if let selected, let message = messages.first(where: { $0.id == selected }) { return (row, message) }
        guard let message = messages.last(where: suits) ?? messages.last else { return nil }
        return (row, message)
    }

    private func copyMessage() {
        guard let (_, message) = target({ !$0.body.isEmpty }) else { return }
        guard !message.body.isEmpty else { return tell("That message has no words to copy.") }
        Desktop.copy(message.body, through: console)
        tell("Copied.")
    }

    private func react(_ emoji: String) {
        guard let (row, message) = target({ row?.chats.unsent[$0.id] == nil }) else { return }
        guard row.chats.unsent[message.id] == nil else { return tell("A message that wasn't delivered can't have reactions.") }
        if !emoji.isEmpty { return perform { try await row.chats.toggleReaction(emoji, on: message) } }
        Task {
            guard let item = await choose("reactions", filterable: false, {
                let current = row.chats.messages(of: row.thread).first { $0.id == message.id } ?? message
                return Self.reactions.map { emoji in
                    let mine = current.reactions.contains(LinkReaction(author: .you, emoji: emoji))
                    return Picker.Item(id: emoji, label: emoji, detail: mine ? "Take back" : "React", current: mine)
                }
            }) else { return }
            let latest = row.chats.messages(of: row.thread).first { $0.id == message.id } ?? message
            do { try await row.chats.toggleReaction(item.id, on: latest) } catch { tell(error.localizedDescription) }
        }
    }

    /// What can be opened from a message: its files, and its links in the order they come.
    private enum Openable {
        case link(URL)
        case file(LinkAttachment)
    }

    private func openables(of message: LinkMessage) -> [Openable] {
        var found: [Openable] = [], links: Set<String> = []
        for attachment in message.attachments {
            if let url = attachment.url {
                if ["http", "https"].contains(url.scheme?.lowercased()), links.insert(url.absoluteString).inserted { found.append(.link(url)) }
            } else {
                found.append(.file(attachment))
            }
        }
        for url in MarkdownText.links(in: message.body) where links.insert(url.absoluteString).inserted { found.append(.link(url)) }
        return found
    }

    private func openFromMessage() {
        guard let (row, message) = target({ !openables(of: $0).isEmpty }) else { return }
        let found = openables(of: message)
        guard !found.isEmpty else { return tell("That message has no links or files.") }
        Task {
            var chosen = found[0]
            if found.count > 1 {
                guard let item = await choose("links and files", verb: "opens", {
                    found.enumerated().map { index, entry in
                        switch entry {
                        case .link(let url): Picker.Item(id: "\(index)", label: url.host() ?? url.absoluteString, detail: url.absoluteString)
                        case .file(let file): Picker.Item(id: "\(index)", label: file.filename, detail: Self.size(of: file))
                        }
                    }
                }), let index = Int(item.id) else { return }
                chosen = found[index]
            }
            do {
                switch chosen {
                case .link(let url):
                    try Desktop.open(url)
                case .file(let file):
                    tell("Downloading \(file.filename)…")
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Noodle Terminal/\(message.id)", isDirectory: true)
                    let downloaded = try await row.chats.download(file, of: message, into: folder)
                    guard try DownloadedAttachment.canOpen(downloaded) else {
                        try Desktop.reveal(downloaded)
                        tell("This attachment can run code. Showed it in its folder.")
                        return
                    }
                    try Desktop.open(downloaded)
                    tell("Opened \(file.filename).")
                }
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    static func size(of file: LinkAttachment) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
    }

    private func saveFromMessage() {
        guard let (row, message) = target({ $0.attachments.contains { $0.url == nil } }) else { return }
        let files = message.attachments.filter { $0.url == nil }
        guard !files.isEmpty else { return tell("That message has no files.") }
        Task {
            var file = files[0]
            if files.count > 1 {
                guard let item = await choose("files", verb: "saves", {
                    files.map { Picker.Item(id: $0.id.uuidString, label: $0.filename, detail: Self.size(of: $0)) }
                }), let chosen = files.first(where: { $0.id.uuidString == item.id }) else { return }
                file = chosen
            }
            do {
                tell("Downloading \(file.filename)…")
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
                let saved = try await row.chats.download(file, of: message, into: downloads)
                tell("Saved to \(saved.path)")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    private func retry() {
        guard let row else { return }
        guard let (_, message) = target({ row.chats.canTryAgain($0) }), row.chats.canTryAgain(message) else {
            return tell("Only the newest message, if it wasn't delivered, can be sent again.")
        }
        selected = nil
        Task { await row.chats.tryAgain(message) }
    }

    static func isDiscardable(_ message: LinkMessage, in chats: HubChats) -> Bool {
        chats.unsent[message.id] != nil && !chats.sending.contains(message.id)
    }

    private func discard() {
        guard let row else { return }
        guard let (_, message) = target({ Self.isDiscardable($0, in: row.chats) }), Self.isDiscardable(message, in: row.chats) else {
            return tell("Only a message that wasn't delivered can be deleted here.")
        }
        selected = nil
        row.chats.deleteUnsent(message)
        tell("Deleted the message that wasn't delivered.")
    }

    private func sendFile(_ typed: String) {
        guard let row else { return }
        guard let path = typedPath(typed, home: FileManager.default.homeDirectoryForCurrentUser.path) else {
            return tell("Type or drop the file's path after /file.")
        }
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            return tell("There is no file at \(url.path).")
        }
        if let reason = row.chats.composerUnavailableReason(for: row.thread) { return tell(reason) }
        scroll = 0
        selected = nil
        perform { try await row.chats.send("", files: [url], to: row.thread) }
    }

    func send(_ text: String) {
        guard let row else { return tell(hubs.chats.isEmpty ? "Join a Hub first: paste an invitation link or code." : "Make a bot first: /new bot") }
        if let reason = row.chats.composerUnavailableReason(for: row.thread) { return tell(reason) }
        scroll = 0
        perform { try await row.chats.send(text, to: row.thread) }
    }

    // MARK: Hubs and help

    func join(_ link: String) {
        guard !link.isEmpty else { return tell("Paste the invitation link or code after /join.") }
        guard !hubs.memberships.isJoining else { return }
        tell("Joining…")
        Task {
            await hubs.join(link)
            if let error = hubs.memberships.joinError { tell(error) } else { tell("Joined.") }
        }
    }

    private func showHelp() {
        Task {
            guard let item = await choose("commands", verb: "runs", { [self] in
                commands.map { Picker.Item(id: $0.name, label: "/" + $0.name + ($0.argument.map { " " + $0 } ?? ""), detail: $0.summary) }
            }), let command = commands.first(where: { $0.name == item.id }) else { return }
            if command.fills { setInput("/\(command.name) ") } else if command.isAvailable() { command.run("") } else { tell(Self.unavailable(command.name)) }
        }
    }
}
