import Foundation
import HubLink

/// What a person does with their bots and groups, beyond chatting, as on the Mac and phone. Each change shows once
/// the Hub has it; the Hub tells the person's other devices.
extension HubChats {
    private func expect(_ response: LinkResponse, _ matches: (LinkResponse) -> Bool) throws {
        guard matches(response) else { throw LinkError("The Hub sent an unexpected answer.") }
    }

    // MARK: Conversations

    /// Pins or unpins on the Hub, for every device. It shows at once, and goes back when the Hub refuses.
    public func setPinned(_ pinned: Bool, _ thread: HubThread) async throws {
        let id = thread.conversationID, before = thread.pinnedAt
        setPin(pinned ? Date() : nil, of: id)
        do {
            _ = try await pairing.request(.pin(LinkPin(conversationID: id, pinned: pinned)))
        } catch {
            setPin(before, of: id)
            throw error
        }
    }

    func setPin(_ date: Date?, of conversationID: UUID) {
        if let index = bots.firstIndex(where: { $0.conversationID == conversationID }) { bots[index].pinnedAt = date }
        if let index = groups.firstIndex(where: { $0.id == conversationID }) { groups[index].pinnedAt = date }
    }

    /// Whether the Hub keeps how each group notifies; an older one does not.
    public var mutesGroups: Bool { pairing.status?.mutesGroups == true }
    /// Whether the Hub knows Mentions only; an older one only mutes.
    public var notifiesMentions: Bool { pairing.status?.notifiesMentions == true }

    /// How a group was set to notify on its own; nil keeps the level for all groups.
    public func chosenNotifications(of group: LinkGroup) -> LinkNotifications? {
        groups.first { $0.id == group.id }?.notifications
    }

    /// Sets how a group notifies, for every device; `default` keeps the level for all groups. A Hub that only mutes
    /// takes All Messages for unmuting.
    public func setNotifications(_ level: LinkNotifications, of group: LinkGroup) async throws {
        let sent = !notifiesMentions && level != .muted ? .all : level
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let before = groups[index].notifications
        groups[index].notifications = sent == .default ? nil : sent
        do {
            _ = try await pairing.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: sent)))
        } catch {
            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].notifications = before }
            throw error
        }
    }

    /// Sets how the user's groups that keep the default notify them, for every device.
    public func setGroupNotifications(_ level: LinkNotifications) async throws {
        try await pairing.setGroupNotifications(level)
    }

    /// Archives or brings back a bot or group, for every device. It keeps everything.
    public func setArchived(_ archived: Bool, _ thread: HubThread) async throws {
        try expect(try await pairing.request(.archive(LinkArchiveChange(id: thread.id, archived: archived)))) {
            if case .done = $0 { true } else { false }
        }
        let date: Date? = archived ? Date() : nil
        if let index = bots.firstIndex(where: { $0.id == thread.id }) { bots[index].archivedAt = date }
        if let index = groups.firstIndex(where: { $0.id == thread.id }) { groups[index].archivedAt = date }
    }

    public var archivedThreads: [HubThread] { threads.filter(\.isArchived) }

    /// Adds your reaction, or takes it back if it is there.
    public func toggleReaction(_ emoji: String, on message: LinkMessage) async throws {
        let present = !message.reactions.contains(LinkReaction(author: .you, emoji: emoji))
        guard case .message(let changed) = try await pairing.request(.react(LinkReactionChange(
            conversationID: message.conversationID, messageID: message.id, emoji: emoji, present: present))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        merge([changed], into: message.conversationID)
    }

    // MARK: A bot's run

    /// Asks the Hub to start a failed bot again; it may first ask what to do.
    public func kick(_ bot: LinkBot) async throws -> LinkKickConfirmation? {
        switch try await pairing.request(.kick(botID: bot.id)) {
        case .done: return nil
        case .kickConfirmation(let confirmation): return confirmation
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    public func confirmKick(_ confirmation: LinkKickConfirmation, for bot: LinkBot) async throws {
        try expect(try await pairing.request(.confirmKick(botID: bot.id, confirmationID: confirmation.id))) {
            if case .done = $0 { true } else { false }
        }
    }

    /// A fresh context for the bot; its workspace, memory and messages are kept.
    public func startNewSession(_ bot: LinkBot) async throws {
        try expect(try await pairing.request(.newSession(botID: bot.id))) { if case .done = $0 { true } else { false } }
    }

    /// Asks a ready bot to tidy its workspace and memory.
    public func organize(_ bot: LinkBot) async throws {
        try expect(try await pairing.request(.organize(botID: bot.id))) { if case .done = $0 { true } else { false } }
    }

    // MARK: Bots and groups

    /// What the Hub lends a new or edited bot, plus the bot's current harness if the plan no longer lends it.
    public func harnesses(keeping draft: LinkBotDraft?) -> [LinkHarness] {
        var lent = pairing.status?.harnesses ?? []
        if let draft, !draft.provider.isEmpty, !lent.contains(where: { $0.provider == draft.provider && $0.profile == draft.profile }) {
            lent.insert(LinkHarness(provider: draft.provider, providerName: draft.provider, profile: draft.profile, profileName: nil), at: 0)
        }
        return lent
    }

    /// Whether the person may share their bots with others on this Hub.
    public var canShareBots: Bool { pairing.status?.canShareBots == true }

    /// Makes a bot and asks it to introduce itself.
    @discardableResult public func create(_ draft: LinkBotDraft) async throws -> LinkBot {
        guard case .bot(let bot) = try await pairing.request(.createBot(draft)) else { throw LinkError("The Hub sent an unexpected answer.") }
        setBots(bots.filter { $0.id != bot.id } + [bot])
        _ = try? await pairing.request(.introduce(conversationID: bot.conversationID))
        return bot
    }

    public func update(_ bot: LinkBot, to draft: LinkBotDraft) async throws {
        guard case .bot(let updated) = try await pairing.request(.updateBot(id: bot.id, draft.leavingOutKnownPicture)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        replace(updated)
    }

    func replace(_ bot: LinkBot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        var kept = pairing.keptPictures([bot])[0]
        if kept.draft.avatarImageData == nil, bots[index].draft.avatarImageDigest == kept.draft.avatarImageDigest {
            kept.draft.avatarImageData = bots[index].draft.avatarImageData
        }
        bots[index] = kept
    }

    /// Deletes the bot and its conversation from the Hub for all the person's devices.
    public func delete(_ bot: LinkBot) async throws {
        try expect(try await pairing.request(.deleteBot(id: bot.id))) { if case .done = $0 { true } else { false } }
        bots.removeAll { $0.id == bot.id }
        conversations[bot.conversationID] = nil
    }

    @discardableResult public func createGroup(_ draft: LinkGroupDraft) async throws -> LinkGroup {
        guard case .group(let group) = try await pairing.request(.createGroup(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        groups = groups.filter { $0.id != group.id } + [group]
        return group
    }

    public func updateGroup(_ group: LinkGroup, to draft: LinkGroupDraft) async throws {
        guard case .group(let updated) = try await pairing.request(.updateGroup(id: group.id, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        if let index = groups.firstIndex(where: { $0.id == updated.id }) { groups[index] = updated }
    }

    public func deleteGroup(_ group: LinkGroup) async throws {
        try expect(try await pairing.request(.deleteGroup(id: group.id))) { if case .done = $0 { true } else { false } }
        groups.removeAll { $0.id == group.id }
        conversations[group.id] = nil
    }

    // MARK: Sharing

    /// The other people on the Hub, to share bots with.
    public func people() async throws -> [LinkPerson] { try await pairing.people() }

    /// Shares the bot with `person`, or stops sharing it.
    public func setShared(_ shared: Bool, _ bot: LinkBot, with person: UUID) async throws {
        var people = Set(bots.first { $0.id == bot.id }?.sharedWith ?? bot.sharedWith)
        if shared { people.insert(person) } else { people.remove(person) }
        guard case .bot(let updated) = try await pairing.request(.shareBot(id: bot.id, people: Array(people))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        replace(updated)
    }

    // MARK: Tools

    public enum Tool: Sendable {
        case connection, computer, browser
    }

    /// Each kind on its own: a Hub that cannot list one still lists the others.
    func loadTools() async {
        try? await loadConnections()
        try? await loadComputers()
        try? await loadBrowsers()
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

    /// The tools of a kind, by name, with whether the bot may use each.
    public func tools(_ kind: Tool, for bot: LinkBot) -> [(id: UUID, name: String, detail: String?, assigned: Bool)] {
        switch kind {
        case .connection:
            connections.map { ($0.id, $0.draft.name, $0.problem ?? ($0.signedIn ? nil : "Not signed in"), $0.botIDs.contains(bot.id)) }
        case .computer:
            computers.map { ($0.id, $0.name, $0.description, $0.botIDs.contains(bot.id)) }
        case .browser:
            browsers.map { ($0.id, $0.name, $0.paused ? "Paused" : $0.description, $0.botIDs.contains(bot.id)) }
        }
    }

    /// Lets the bot use a tool, or stops it.
    public func setAssigned(_ assigned: Bool, _ kind: Tool, _ id: UUID, for bot: LinkBot) async throws {
        var ids = Set(tools(kind, for: bot).filter(\.assigned).map(\.id))
        if assigned { ids.insert(id) } else { ids.remove(id) }
        switch kind {
        case .connection:
            _ = try await pairing.request(.assignConnections(botID: bot.id, connectionIDs: Array(ids)))
            try await loadConnections()
        case .computer:
            _ = try await pairing.request(.assignComputers(botID: bot.id, computerIDs: Array(ids)))
            try await loadComputers()
        case .browser:
            _ = try await pairing.request(.assignBrowsers(botID: bot.id, browserIDs: Array(ids)))
            try await loadBrowsers()
        }
    }

    // MARK: Files

    /// Saves a message's file from the Hub into `folder`, under a name no other file there has, and returns where.
    public func download(_ attachment: LinkAttachment, of message: LinkMessage, into folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = Self.freeName(for: attachment.filename, in: folder)
        do {
            try await pairing.download(attachment, from: message.conversationID, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// `name` in `folder`, or with a number before its extension when that is taken, as Finder does.
    static func freeName(for name: String, in folder: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe.isEmpty ? "File" : safe), number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// A small picture of a file, scaled down by the Hub: a picture, a video's first frame or a PDF's first page.
    public func preview(of attachment: LinkAttachment, in message: LinkMessage, pixels: Int) async throws -> Data? {
        guard case .picture(let data) = try await pairing.request(.attachmentPreview(
            conversationID: message.conversationID, attachmentID: attachment.id, pixels: pixels)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return data
    }
}
