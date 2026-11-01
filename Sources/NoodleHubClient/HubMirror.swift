import Foundation
import HubLink
import NoodleCore
import Observation

/// This Mac's copy of the bots it keeps on one Noodle Hub. The Hub runs the bots and holds
/// their conversations; the copy lets Noodle show and send like any other bot. Message IDs
/// are the Hub's, so nothing is doubled however often the two are compared.
@MainActor @Observable public final class HubMirror {
    /// One bot on the Hub and its local stand-in.
    struct Entry: Codable, Equatable {
        var remote: UUID
        var remoteConversation: UUID
        var agent: UUID
        var conversation: UUID
        /// How many of the Hub's messages this copy has.
        var synced: Int
        /// The Hub's profile for the harness, which means nothing on this Mac.
        var profile: UUID?
        /// The Hub's background for the conversation, as last copied here.
        var background: LinkBackground?
        /// Whose it is, when someone shared it with this Mac's user.
        var owner: String?
        /// Whom it is shared with, when it is this Mac's user's.
        var sharedWith: [UUID]?
        /// Whether the Hub takes calls with it. Nil from before calls.
        var canCall: Bool?
        /// When this Mac's user pinned it, as the Hub last said, so pins show before the Hub answers.
        var pinnedAt: Date?
        /// Whether it may make images with the Hub's image models.
        var imageGeneration: Bool?
    }

    /// A group of bots on the Hub and its local copy.
    struct GroupEntry: Codable, Equatable {
        var remote: UUID
        var conversation: UUID
        var synced: Int
        var background: LinkBackground?
        var pinnedAt: Date?
        /// How it notifies this Mac's user, as the Hub last said. Nil for every reply.
        var notifications: LinkNotifications?
    }

    /// A conversation on the Hub, a bot's own or a group's, and its local copy.
    private struct Thread {
        var remote: UUID
        var local: UUID
        var synced: Int
        var background: LinkBackground?
    }

    public private(set) var isConnected = false
    public private(set) var error: String?
    /// Runs when bots here were added, removed or changed, so the app can reload them.
    /// New messages need no call: they land in the conversation files the app already watches.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Runs with how far this Mac's user has read a conversation here, as the Hub keeps it: read on
    /// another device, or as the Hub had it when this Mac connected.
    @ObservationIgnored public var onRead: ((_ conversation: UUID, _ upTo: Date) -> Void)?
    /// Runs with a conversation here whose background changed to the Hub's.
    @ObservationIgnored public var onBackgroundChanged: ((_ conversation: UUID) -> Void)?
    /// Runs with a group here whose notifications changed, here or on another device, or with each group when the level for all groups did.
    @ObservationIgnored public var onNotificationsChanged: ((_ conversation: UUID) -> Void)?
    /// One of this Mac's user's bots on the Hub is calling them, with the bot and conversation here.
    @ObservationIgnored public var onCallRinging: ((AgentCallRequest) -> Void)?
    /// A call that rang was answered on some device, declined, or not answered in time.
    @ObservationIgnored public var onCallStopped: ((_ id: UUID) -> Void)?
    /// This Mac's user's tool connections on the Hub, as last listed.
    public private(set) var connections: [LinkConnection] = []
    /// This Mac's user's computers on the Hub, as last listed.
    public private(set) var computers: [LinkComputer] = []
    /// This Mac's user's browsers on the Hub, as last listed.
    public private(set) var browsers: [LinkBrowser] = []
    /// Counts the Hub saying its users changed, which it tells admins only, so their list can follow.
    public private(set) var usersChanges = 0
    /// What each bot is doing on the Hub, by its stand-in here.
    private var phases: [UUID: AgentRuntimePhase] = [:]
    /// Why each bot on the Hub does not answer for now, by its stand-in here, as the Hub last listed it.
    private var pauses: [UUID: LinkBotPause] = [:]
    /// Computers being made, waiting for the Hub to say they are done.
    @ObservationIgnored private var making: [UUID: CheckedContinuation<LinkComputer, Error>] = [:]
    /// Opens a connection's sign-in page in the browser and returns the address it came back to.
    @ObservationIgnored public var onSignInPage: ((LinkConnection, URL) async throws -> URL)?


    public let pairing: HubPairing
    /// This Mac's own bots that people on the Hub talk to.
    public let hosting: HubHosting
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let url: URL
    private var entries: [Entry] = []
    @ObservationIgnored private let groupsURL: URL
    private var groups: [GroupEntry] = []
    /// The names of the other people on the Hub, as last listed, for the bots shared with them.
    private var peopleNames: [UUID: String] = [:]
    /// Local messages the Hub already has, so they are not sent again.
    @ObservationIgnored private var acknowledged: Set<UUID> = []
    /// Conversations on the Hub whose background is being sent from here, which the Hub's answer settles.
    @ObservationIgnored private var sharingBackgrounds: Set<UUID> = []

    public init(pairing: HubPairing, repository: WorkspaceRepository, directory: URL) {
        self.pairing = pairing
        self.repository = repository
        hosting = HubHosting(pairing: pairing, repository: repository, directory: directory)
        url = directory.appendingPathComponent("mirror.json")
        groupsURL = directory.appendingPathComponent("groups.json")
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
        groups = (try? JSONDecoder().decode([GroupEntry].self, from: Data(contentsOf: groupsURL))) ?? []
    }

    public var localAgentIDs: Set<UUID> { Set(entries.map(\.agent)) }

    public func owns(conversation id: UUID) -> Bool { thread(local: id) != nil }

    /// The local copies of this Hub's bots' conversations and its groups.
    public var localConversationIDs: [UUID] { threads.map(\.local) }

    private var threads: [Thread] {
        entries.map { Thread(remote: $0.remoteConversation, local: $0.conversation, synced: $0.synced, background: $0.background) }
            + groups.map { Thread(remote: $0.remote, local: $0.conversation, synced: $0.synced, background: $0.background) }
    }

    /// A conversation's ID on the Hub, as the person's other devices know it.
    public func remoteConversation(local id: UUID) -> UUID? { thread(local: id)?.remote }

    /// The local copy of a conversation on the Hub.
    public func localConversation(remote id: UUID) -> UUID? { thread(remote: id)?.local }

    private func thread(remote id: UUID) -> Thread? { threads.first { $0.remote == id } }

    private func thread(local id: UUID) -> Thread? { threads.first { $0.local == id } }

    /// Conversations here where a chat effect may wait on the Hub: it said so, or this Mac was away when it might have.
    @ObservationIgnored private var waitingEffects: Set<UUID> = []

    public func hasWaitingEffect(in conversation: UUID) -> Bool { waitingEffects.contains(conversation) }

    /// Takes the chat effect waiting on the Hub in a conversation here, now that it is in front, so it plays on no
    /// other device. Nil when none waits, or when the Hub cannot be asked now; it is asked again once it says so.
    public func takeEffect(in conversation: UUID) async -> LinkEffect? {
        guard waitingEffects.remove(conversation) != nil, let thread = thread(local: conversation),
              case .effect(let effect)? = try? await pairing.request(.takeEffect(conversationID: thread.remote)) else { return nil }
        return effect
    }

    /// What the bot a stand-in here keeps on the Hub is doing there, as last heard.
    public func phase(ofAgent id: UUID) -> AgentRuntimePhase? { phases[id] }

    /// Why the bot a stand-in here keeps on the Hub does not answer for now, as the Hub last listed it. Nil while it runs,
    /// and from a Hub that does not say.
    public func pause(ofAgent id: UUID) -> LinkBotPause? { pairing.status?.explainsPauses == true ? pauses[id] : nil }

    private func record(_ phase: LinkBotPhase?, ofBot remote: UUID) {
        guard let agent = entries.first(where: { $0.remote == remote })?.agent else { return }
        phases[agent] = phase.flatMap { AgentRuntimePhase(rawValue: $0.rawValue) }
    }

    /// Opens the live view of what a link in a conversation here points at, kept on the Hub. Video
    /// comes down the channel as `LinkSurface` messages; send the viewer's controls up it with `LinkSurface.control`.
    public func openSurface(attachment: UUID, in conversation: UUID) async throws -> LinkChannel {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        return try await pairing.channel(.openSurface(conversationID: thread.remote, attachmentID: attachment))
    }

    /// Whether the Hub finds and fills the sign-in fields of a browser watched live.
    public var signsInToBrowsers: Bool { pairing.status?.signsInToBrowsers == true }

    /// The sign-in fields of the page a browser card in a conversation here shows, while this Mac watches it live.
    public func signInForm(attachment: UUID, in conversation: UUID) async throws -> LinkSignInForm {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        guard case .signInForm(let form) = try await pairing.request(.signInForm(conversationID: thread.remote, attachmentID: attachment)) else {
            throw LinkError("The Hub did not answer. Try again.")
        }
        return form
    }

    /// Fills the form `signInForm` found with what the person entered, once.
    public func fillSignIn(_ entry: LinkSignInEntry, form: LinkSignInForm, attachment: UUID, in conversation: UUID) async throws {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        _ = try await pairing.request(.fillSignIn(entry.fill(form, conversationID: thread.remote, attachmentID: attachment)))
    }

    /// Whether the Hub takes calls with a bot here, as it said when it last listed it.
    public func canCall(agent: UUID) -> Bool { entries.first { $0.agent == agent }?.canCall == true }

    /// Whether a call can start now. A call needs the bot running, unlike a message, which it picks up later: the
    /// Hub in reach, the bot ready or working, and not paused.
    public func canCallNow(agent: UUID) -> Bool {
        Self.canCallNow(canCall: canCall(agent: agent), isConnected: isConnected, phase: phase(ofAgent: agent),
                        isPaused: pause(ofAgent: agent) != nil)
    }

    /// A Hub that does not say how its bot is lets the call be tried.
    public static func canCallNow(canCall: Bool, isConnected: Bool, phase: AgentRuntimePhase?, isPaused: Bool) -> Bool {
        guard canCall, isConnected, !isPaused else { return false }
        switch phase {
        case .offline, .starting, .failed: return false
        default: return true
        }
    }

    /// Calls the bot of a conversation here on the Hub. What happens comes down the channel as
    /// `LinkCallEvent`s among the bot's `LinkCallAudio`, which the person's goes up; cancelling it hangs up.
    /// `answering` names the call the bot placed, as `onCallRinging` gave it, when this answers it.
    public func openCall(in conversation: UUID, answering: UUID? = nil) async throws -> LinkChannel {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        return try await pairing.channel(.startCall(LinkCallStart(conversationID: thread.remote, answering: answering)))
    }

    /// Declines a call a bot on the Hub placed; the Hub leaves it as declined and stops it ringing everywhere.
    public func declineCall(_ id: UUID) async throws {
        _ = try await pairing.request(.declineCall(id: id))
    }

    /// Opens a noodlet a bot shared in a conversation here to run on this Mac.
    public func openNoodlet(attachment: UUID, in conversation: UUID) async throws -> LinkNoodletSession {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        let pairing = pairing
        return try await LinkNoodletSession.open(conversationID: thread.remote, attachmentID: attachment) {
            try await pairing.request($0)
        }
    }

    /// Where this Hub's noodlets are kept on this Mac.
    public var noodletCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noodlets/\(pairing.directory.lastPathComponent)")
    }

    /// The Hub harness a local stand-in runs on.
    public func harness(ofAgent id: UUID) -> HubHarnessChoice? {
        guard let entry = entries.first(where: { $0.agent == id }), entry.owner == nil,
              let agent = try? repository.loadAgents().first(where: { $0.id == id }) else { return nil }
        return HubHarnessChoice(hub: pairing.hub?.key, provider: agent.harnessIdentifier ?? "", profile: entry.profile)
    }

    /// Deletes the local stand-ins, as when leaving the Hub. The bots stay on the Hub.
    public func forgetLocalCopies() {
        for group in groups { try? forget(group) }
        for entry in entries { try? forget(entry) }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: groupsURL)
        hosting.forgetLocalCopies()
        onChange?()
    }

    public func createBot(_ draft: LinkBotDraft) async throws -> AgentRecord {
        guard case .bot(let bot) = try await pairing.request(.createBot(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        let agent = try adopt(bot)
        onChange?()
        return agent
    }

    /// Asks a bot just made on the Hub to introduce itself in its conversation.
    public func introduce(_ localAgentID: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        guard case .done = try await pairing.request(.introduce(conversationID: entry.remoteConversation)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    public func updateBot(localAgentID: UUID, with draft: LinkBotDraft) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        guard case .bot(let bot) = try await pairing.request(.updateBot(id: entry.remote, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try apply(bot, to: entry)
        onChange?()
    }

    /// The other people on the Hub, to share a bot with.
    public func people() async throws -> [LinkPerson] {
        try await fetchPeople()
    }

    /// How long the people on the Hub are kept before they are fetched again, in the background.
    nonisolated public static let peopleKeptFor: TimeInterval = 60
    /// How long the owner's phone waits for the people on a Hub not asked before, before leaving it out.
    nonisolated public static let peopleWait: Duration = .seconds(3)
    /// When it is, for keeping the people; tests pass their own.
    @ObservationIgnored public var now: () -> Date = Date.init
    /// The people on the Hub, as last fetched, and when.
    @ObservationIgnored private var keptPeople: (people: [LinkPerson], at: Date)?
    /// The fetch under way, which everyone asking meanwhile waits for.
    @ObservationIgnored private var fetchingPeople: Task<[LinkPerson], Error>?

    /// Fetches the people on the Hub once however many ask at the same time, and keeps them and their names.
    private func fetchPeople() async throws -> [LinkPerson] {
        if let fetchingPeople { return try await fetchingPeople.value }
        let fetch = Task { try await pairing.people() }
        fetchingPeople = fetch
        defer { if fetchingPeople == fetch { fetchingPeople = nil } }
        let people = try await fetch.value
        keptPeople = (people, now())
        peopleNames = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return people
    }

    /// The people on the Hub at once when kept, fetching newer ones in the background once they are a while
    /// old; otherwise fetched, waiting at most `wait`. A fetch that takes longer is kept for next time.
    private func knownPeople(within wait: Duration) async -> [LinkPerson]? {
        if let kept = keptPeople {
            if now().timeIntervalSince(kept.at) > Self.peopleKeptFor, fetchingPeople == nil {
                Task { _ = try? await fetchPeople() }
            }
            return kept.people
        }
        // Whichever comes first: a task group would wait out the fetch, which goes on to be kept.
        let fetch = Task { try? await fetchPeople() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[LinkPerson]?, Never>) in
            let race = FirstAnswer(continuation)
            Task { @MainActor in race.answer(await fetch.value) }
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                race.answer(nil)
            }
        }
    }

    /// What this Hub is known by to this Mac's own devices, which share its bots through it.
    public var sharingID: String { pairing.hub?.key.x963.base64EncodedString() ?? pairing.directory.lastPathComponent }

    /// A bot on this Mac's sharing on this Hub, for its owner's phone.
    public func sharing(of agent: UUID, within wait: Duration = HubMirror.peopleWait) async throws -> LinkHubSharing {
        guard let people = await knownPeople(within: wait) else { throw LinkError("\(pairing.hub?.name ?? "The Hub") did not answer.") }
        return LinkHubSharing(id: sharingID, name: pairing.hub?.name ?? "Noodle Hub", people: people,
                              sharedWith: hosting.sharedWith(agent: agent))
    }

    /// Shares one of this Mac's user's bots on the Hub with exactly `people`.
    public func share(localAgentID: UUID, with people: [UUID]) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        guard case .bot(let bot) = try await pairing.request(.shareBot(id: entry.remote, people: people)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try apply(bot, to: entry)
        await listPeople()
        onChange?()
    }

    /// Learns the names of the people the bots here are shared with. A Hub that does not answer keeps the last names.
    private func listPeople() async {
        guard entries.contains(where: { !($0.sharedWith ?? []).isEmpty }) else { return }
        _ = try? await fetchPeople()
    }

    /// Whom a bot of this Mac's user is shared with on the Hub.
    /// Whether a bot may make images with the Hub's image models.
    public func imageGeneration(forAgent id: UUID) -> Bool { entries.first { $0.agent == id }?.imageGeneration ?? false }

    /// The Hub's default image model, which its bots with Image Generation use. Nil while it has none.
    public var imageModel: String? { pairing.status?.imageModel }

    public func sharedWith(agent id: UUID) -> [UUID] { entries.first { $0.agent == id }?.sharedWith ?? [] }

    /// The names of the people a bot of this Mac's user is shared with on the Hub.
    public func sharedNames(agent id: UUID) -> [String] { sharedWith(agent: id).compactMap { peopleNames[$0] } }

    /// Whose a bot someone shared with this Mac's user is; nil for their own. They only talk with it.
    public func owner(ofAgent id: UUID) -> String? { entries.first { $0.agent == id }?.owner }

    public func deleteBot(localAgentID: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        _ = try await pairing.request(.deleteBot(id: entry.remote))
        try forget(entry)
        onChange?()
    }

    /// Archives or brings back a bot on the Hub, for every device, and its copy here.
    public func setArchived(_ archived: Bool, localAgentID: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        _ = try await pairing.request(.archive(LinkArchiveChange(id: entry.remote, archived: archived)))
        try repository.setAgentArchived(archived, agentID: localAgentID)
        onChange?()
    }

    public func setArchived(_ archived: Bool, conversation: UUID) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        _ = try await pairing.request(.archive(LinkArchiveChange(id: entry.remote, archived: archived)))
        try repository.setConversationArchived(archived, conversationID: conversation)
        onChange?()
    }

    /// The local copies of this Hub's conversations its user pinned, in the order they were pinned.
    public var pinnedConversations: [UUID] {
        (entries.compactMap { entry in entry.pinnedAt.map { ($0, entry.conversation) } }
            + groups.compactMap { group in group.pinnedAt.map { ($0, group.conversation) } })
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Pins or unpins a conversation on the Hub, for every device of its user. It shows here at once,
    /// and goes back when the Hub refuses.
    public func setPinned(_ pinned: Bool, conversation: UUID) async throws {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        let before = pinnedAt(remote: thread.remote)
        guard (before != nil) != pinned else { return }
        setPinnedAt(pinned ? Date() : nil, remote: thread.remote)
        do {
            _ = try await pairing.request(.pin(LinkPin(conversationID: thread.remote, pinned: pinned)))
        } catch {
            setPinnedAt(before, remote: thread.remote)
            throw error
        }
    }

    /// Whether the Hub can mute groups; an older one cannot.
    public var mutesGroups: Bool { pairing.status?.mutesGroups == true }

    /// Whether the Hub knows Mentions only, for a group and for all of them; an older one only mutes.
    public var notifiesMentions: Bool { pairing.status?.notifiesMentions == true }

    /// How this Hub's groups that keep the default notify its user.
    public var groupNotifications: LinkNotifications { pairing.status?.groupNotifications ?? .all }

    /// The name that mentions this Hub's user, as the Hub lists them.
    public var mentionName: String { pairing.status?.userName ?? pairing.hub?.userName ?? "" }

    /// The local copies of this Hub's groups its user muted.
    public var mutedConversations: Set<UUID> { Set(groups.filter { $0.notifications == .muted }.map(\.conversation)) }

    /// How the local copy of a group on this Hub was set to notify. Nil keeps the default.
    public func notifications(of conversation: UUID) -> LinkNotifications? {
        groups.first { $0.conversation == conversation }?.notifications
    }

    /// Sets how a group notifies, `default` keeping the level for all groups, on the Hub, for every device of its user.
    /// It shows here at once, and goes back when the Hub refuses. A Hub that only mutes takes All Messages for unmuting.
    public func setNotifications(_ level: LinkNotifications, conversation: UUID) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        let sent = !notifiesMentions && level != .muted ? .all : level
        let before = entry.notifications
        guard before != (sent == .default ? nil : sent) else { return }
        setNotifications(sent, remote: entry.remote)
        do {
            _ = try await pairing.request(.setNotifications(LinkNotificationsChange(conversationID: entry.remote, notifications: sent)))
        } catch {
            setNotifications(before, remote: entry.remote)
            throw error
        }
    }

    /// Sets how this Hub's groups that keep the default notify its user, for every device.
    public func setGroupNotifications(_ level: LinkNotifications) async throws {
        defer { groups.forEach { onNotificationsChanged?($0.conversation) } }
        try await pairing.setGroupNotifications(level)
    }

    private func setNotifications(_ level: LinkNotifications?, remote id: UUID) {
        let kept = level == .default ? nil : level
        guard let index = groups.firstIndex(where: { $0.remote == id }), groups[index].notifications != kept else { return }
        groups[index].notifications = kept
        saveGroups()
        onNotificationsChanged?(groups[index].conversation)
    }

    private func pinnedAt(remote id: UUID) -> Date? {
        entries.first { $0.remoteConversation == id }?.pinnedAt ?? groups.first { $0.remote == id }?.pinnedAt
    }

    private func setPinnedAt(_ date: Date?, remote id: UUID) {
        if let index = entries.firstIndex(where: { $0.remoteConversation == id }), entries[index].pinnedAt != date {
            entries[index].pinnedAt = date
            save()
        }
        if let index = groups.firstIndex(where: { $0.remote == id }), groups[index].pinnedAt != date {
            groups[index].pinnedAt = date
            saveGroups()
        }
    }

    /// Makes a group on the Hub of bots kept there, by their local stand-ins, and its local copy.
    public func createGroup(named name: String, publicDescription: String, agentIDs: [UUID]) async throws -> BotConversation {
        let draft = LinkGroupDraft(name: name, publicDescription: publicDescription, botIDs: try remoteBots(agentIDs))
        guard case .group(let group) = try await pairing.request(.createGroup(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        let conversation = try adopt(group)
        onChange?()
        return conversation
    }

    public func updateGroup(_ conversation: UUID, named name: String, publicDescription: String, agentIDs: [UUID]) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        let draft = LinkGroupDraft(name: name, publicDescription: publicDescription, botIDs: try remoteBots(agentIDs))
        guard case .group(let group) = try await pairing.request(.updateGroup(id: entry.remote, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try apply(group, to: entry)
        onChange?()
    }

    /// Deletes a group here and on the Hub. Its bots stay.
    public func deleteGroup(_ conversation: UUID) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        _ = try await pairing.request(.deleteGroup(id: entry.remote))
        try forget(entry)
        onChange?()
    }

    private func remoteBots(_ agentIDs: [UUID]) throws -> [UUID] {
        try agentIDs.map { id in
            guard let remote = entries.first(where: { $0.agent == id })?.remote else { throw LinkError("A bot in this group is not on this Hub.") }
            return remote
        }
    }

    /// Adds a connection on the Hub, or changes one. It reaches no bot until assigned.
    @discardableResult public func saveConnection(_ draft: LinkConnectionDraft) async throws -> LinkConnection {
        guard case .connection(let saved) = try await pairing.request(.saveConnection(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncConnections()
        return saved
    }

    public func deleteConnection(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteConnection(id: id))
        try await syncConnections()
    }

    /// The Hub connections a bot kept there may use, by its local stand-in.
    public func connectionIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(connections.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignConnections(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignConnections(botID: entry.remote, connectionIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncConnections()
    }

    /// Asks the Hub to sign a connection in; its page opens through `onSignInPage`.
    public func signIn(_ id: UUID, redirect: URL) async throws {
        try await pairing.signIn(connectionID: id, redirect: redirect)
    }

    public func computerTemplates() async throws -> [LinkComputerTemplate] {
        guard case .computerTemplates(let templates) = try await pairing.request(.computerTemplates) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return templates
    }

    /// Makes a computer on the Hub, which may first download its image. Needs `run` to be
    /// following the Hub, which says when the computer is ready.
    public func createComputer(_ draft: LinkComputerDraft) async throws -> LinkComputer {
        let id = UUID()
        let made = try await withCheckedThrowingContinuation { continuation in
            making[id] = continuation
            Task {
                do { _ = try await pairing.request(.createComputer(requestID: id, draft)) }
                catch { making.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
        try await syncComputers()
        return made
    }

    public func updateComputer(_ id: UUID, with draft: LinkComputerDraft) async throws -> LinkComputer {
        guard case .computer(let changed) = try await pairing.request(.updateComputer(id: id, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncComputers()
        return changed
    }

    public func deleteComputer(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteComputer(id: id))
        try await syncComputers()
    }

    /// The Hub computers a bot kept there may use, by its local stand-in.
    public func computerIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(computers.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignComputers(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignComputers(botID: entry.remote, computerIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncComputers()
    }

    public func createBrowser(_ draft: LinkBrowserDraft) async throws -> LinkBrowser {
        guard case .browser(let made) = try await pairing.request(.createBrowser(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncBrowsers()
        return made
    }

    /// Lists this Mac's user's computers on the Hub again. Throws for a Hub that keeps none or cannot list them now.
    public func refreshComputers() async throws { try await syncComputers() }

    /// Lists this Mac's user's browsers on the Hub again. Throws for a Hub that keeps none or cannot list them now.
    public func refreshBrowsers() async throws { try await syncBrowsers() }

    /// The local stand-in of one of this Mac's user's bots on the Hub.
    public func localAgentID(remote id: UUID) -> UUID? { entries.first { $0.remote == id }?.agent }

    public func updateBrowser(_ id: UUID, with draft: LinkBrowserDraft) async throws -> LinkBrowser {
        guard case .browser(let changed) = try await pairing.request(.updateBrowser(id: id, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncBrowsers()
        return changed
    }

    public func deleteBrowser(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteBrowser(id: id))
        try await syncBrowsers()
    }

    /// The Hub browsers a bot kept there may use, by its local stand-in.
    public func browserIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(browsers.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignBrowsers(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignBrowsers(botID: entry.remote, browserIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncBrowsers()
    }

    private func syncBrowsers() async throws {
        guard case .browsers(let listed) = try await pairing.request(.browsers) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        browsers = pairing.keptPictures(listed)
    }

    private func syncComputers() async throws {
        guard case .computers(let listed) = try await pairing.request(.computers) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        computers = pairing.keptPictures(listed)
    }

    private func syncConnections() async throws {
        guard case .connections(let listed) = try await pairing.request(.connections) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        connections = pairing.keptPictures(listed)
    }

    private func openSignInPage(_ id: UUID, url: URL) async {
        do {
            guard pairing.takeSignInPage(for: id, url: url) else {
                throw LinkError("Noodle did not open a sign-in page it had not asked for.")
            }
            guard let connection = connections.first(where: { $0.id == id }), let onSignInPage else {
                throw LinkError("This Mac cannot open that sign-in.")
            }
            let callback = try await onSignInPage(connection, url)
            _ = try await pairing.request(.finishSignIn(connectionID: id, callback: callback))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Brings bots and messages up to date with the Hub, and sends what is waiting here.
    public func sync() async {
        do {
            try await syncBots()
            do { try await syncGroups() } catch {
                // A Hub from before groups says it does not know the request; it has none to copy.
            }
            // Effects sent while this Mac was away were heard of by nobody here, whatever else fails to sync.
            waitingEffects.formUnion(threads.map(\.local))
            try await syncConnections()
            try await syncComputers()
            try await syncBrowsers()
            for thread in threads { try await syncMessages(thread.remote) }
            // Files earlier versions downloaded with every message go too, past the limit.
            dropOldFiles()
            try await sendPending()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sends messages written here that the Hub does not have yet.
    public func pushPending() async {
        do {
            try await sendPending()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keeps a stream open to the Hub and follows what it pushes, reconnecting until cancelled.
    public func run() async {
        // This Mac's own bots take part through the same stream.
        let hosted = Task { await hosting.run() }
        defer { hosted.cancel() }
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                let events = try await pairing.subscribe()
                isConnected = true
                hosting.isConnected = true
                delay = .seconds(1)
                await sync()
                for try await event in events {
                    hosting.heard(event)
                    switch event {
                    case .botsChanged:
                        try await syncBots()
                    case .groupsChanged:
                        try await syncGroups()
                    case .conversationChanged(let id, _):
                        try await syncMessages(id)
                    case .connectionsChanged:
                        try await syncConnections()
                    case .computersChanged:
                        try await syncComputers()
                    case .browsersChanged:
                        try await syncBrowsers()
                    // Surfaces have their own streams.
                    case .surfaceOpened, .surfaceFailed, .surfaceControls:
                        break
                    case .computerCreated(let id, let computer, let error):
                        if let computer { making.removeValue(forKey: id)?.resume(returning: computer) }
                        else { making.removeValue(forKey: id)?.resume(throwing: LinkError(error ?? "The Hub could not make the computer.")) }
                    case .signInPage(let id, let url):
                        // The person may take minutes in the browser; other events keep flowing meanwhile.
                        Task { await openSignInPage(id, url: url) }
                    case .botPhase(let bot, let phase):
                        record(phase, ofBot: bot)
                    // Reactions made on the Hub are not shown on the Mac yet; a call's card is.
                    case .messageChanged(let message):
                        if message.call != nil { try await syncMessages(message.conversationID) }
                    case .usersChanged:
                        usersChanges += 1
                    case .effectWaiting(let id):
                        if let thread = thread(remote: id) { waitingEffects.insert(thread.local) }
                    case .readChanged(let id, let upTo):
                        if let thread = thread(remote: id) { onRead?(thread.local, upTo) }
                    case .pinChanged(let id, let pinnedAt):
                        setPinnedAt(pinnedAt, remote: id)
                    case .notificationsChanged(let id, let level):
                        setNotifications(level, remote: id)
                    case .groupNotificationsChanged(let level):
                        pairing.groupNotificationsChanged(to: level)
                        groups.forEach { onNotificationsChanged?($0.conversation) }
                    case .backgroundChanged(let id, let background):
                        // One that cannot be fetched now is tried again at the next sync.
                        try? await copyBackground(background, of: id)
                    case .callRinging(let call):
                        guard let agent = entries.first(where: { $0.remote == call.botID })?.agent,
                              let thread = thread(remote: call.conversationID) else { break }
                        onCallRinging?(AgentCallRequest(id: call.id, agentID: agent, conversationID: thread.local, reason: call.reason,
                                                        requestedAt: Date(), expiresAt: Date().addingTimeInterval(call.secondsLeft)))
                    case .callStopped(let id):
                        onCallStopped?(id)
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            isConnected = false
            hosting.isConnected = false
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
        isConnected = false
        hosting.isConnected = false
    }

    private func syncBots() async throws {
        guard case .bots(let listed) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        await pairing.fetchPictures(listed)
        let bots = pairing.keptPictures(listed)
        var changed = false
        for bot in bots {
            if let entry = entries.first(where: { $0.remote == bot.id }) {
                try apply(bot, to: entry)
            } else {
                _ = try adopt(bot)
                changed = true
            }
        }
        for entry in entries where !bots.contains(where: { $0.id == entry.remote }) {
            try forget(entry)
            changed = true
        }
        for bot in bots { record(bot.phase, ofBot: bot.id) }
        pauses = Dictionary(bots.compactMap { bot in
            entries.first { $0.remote == bot.id }.flatMap { entry in bot.pause.map { (entry.agent, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        await listPeople()
        if changed { onChange?() }
        for bot in bots { if let background = bot.background { try? await copyBackground(background, of: bot.conversationID) } }
        for bot in bots {
            if let upTo = bot.readUpTo, let entry = entries.first(where: { $0.remote == bot.id }) { onRead?(entry.conversation, upTo) }
        }
    }

    private func syncGroups() async throws {
        guard case .groups(let listed) = try await pairing.request(.groups) else { throw LinkError("The Hub sent an unexpected answer.") }
        var changed = false
        for group in listed {
            if let entry = groups.first(where: { $0.remote == group.id }) {
                if try apply(group, to: entry) { changed = true }
                setPinnedAt(group.pinnedAt, remote: group.id)
                setNotifications(group.notifications, remote: group.id)
            } else {
                _ = try adopt(group)
                changed = true
            }
        }
        for entry in groups where !listed.contains(where: { $0.id == entry.remote }) {
            try forget(entry)
            changed = true
        }
        if changed { onChange?() }
        for group in listed { if let background = group.background { try? await copyBackground(background, of: group.id) } }
        for group in listed {
            if let upTo = group.readUpTo, let entry = groups.first(where: { $0.remote == group.id }) { onRead?(entry.conversation, upTo) }
        }
    }

    /// This Mac's user read a conversation here, up to its latest message the Hub has; their other devices show it read.
    public func markRead(conversation id: UUID) async {
        guard let thread = thread(local: id),
              let latest = try? repository.loadMessages(conversationID: id)
                .last(where: { $0.author != .user || $0.delivery != .queued || acknowledged.contains($0.id) }) else { return }
        do {
            _ = try await pairing.request(.markRead(LinkReadMark(conversationID: thread.remote, messageID: latest.id)))
        } catch {
            // A Hub from before read state was shared says it does not know the request; the Mac keeps its own.
        }
    }

    /// Makes a conversation's background here the Hub's, fetching its file once until it changes.
    private func copyBackground(_ background: LinkBackground, of remote: UUID) async throws {
        guard let thread = thread(remote: remote), thread.background != background, !sharingBackgrounds.contains(remote) else { return }
        if let media = background.media {
            // Only a name a Hub gives becomes a file here.
            guard let filename = background.mediaFilename else { throw LinkError("The Hub sent a background this Noodle cannot use.") }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-background-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let file = staging.appendingPathComponent(filename)
            try await pairing.downloadBackground(media, of: remote, compact: false, to: file)
            try repository.setBackground(conversationID: thread.local, file: try await PreparedBackgroundFile.prepare(file))
        } else {
            try repository.setBackground(conversationID: thread.local, preset: background.preset.flatMap(ConversationBackgroundPreset.init(rawValue:)))
        }
        setBackground(background, in: remote)
        onBackgroundChanged?(thread.local)
    }

    /// Sends the background a conversation here has to the Hub, for every device. A Hub that does
    /// not keep backgrounds leaves this Mac's own.
    public func shareBackground(conversation id: UUID) async {
        guard let thread = thread(local: id), let background = try? repository.loadBackground(conversationID: id) else { return }
        sharingBackgrounds.insert(thread.remote)
        defer { sharingBackgrounds.remove(thread.remote) }
        do {
            let kept: LinkBackground
            if let file = repository.backgroundImageURL(background, conversationID: id) {
                kept = try await pairing.uploadBackground(file, to: thread.remote)
            } else {
                guard case .background(let answer) = try await pairing.request(.setBackground(
                    LinkBackgroundChoice(conversationID: thread.remote, preset: background.preset?.rawValue))) else {
                    throw LinkError("The Hub sent an unexpected answer.")
                }
                kept = answer
            }
            setBackground(kept, in: thread.remote)
            error = nil
        } catch let failure as LinkError where failure.message == LinkProtocol.unknownRequest {
            // An older Hub.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setBackground(_ background: LinkBackground, in remote: UUID) {
        if let entry = entries.first(where: { $0.remoteConversation == remote }) {
            update(entry.remote) { $0.background = background }
        } else if let index = groups.firstIndex(where: { $0.remote == remote }), groups[index].background != background {
            groups[index].background = background
            saveGroups()
        }
    }

    /// Copies what is new on the Hub a page at a time, so no answer grows with the conversation.
    private func syncMessages(_ remote: UUID) async throws {
        guard var thread = thread(remote: remote) else { return }
        while true {
            let page = try await syncPage(thread)
            guard let next = self.thread(remote: remote),
                  next.synced > thread.synced, next.synced < page.count, page.messages.count > 0 else { return }
            thread = next
        }
    }

    private func syncPage(_ thread: Thread) async throws -> LinkMessages {
        guard case .messages(let page) = try await pairing.request(.messagePage(LinkMessagePage(
            conversationID: thread.remote, after: thread.synced, limit: 100))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        var known = Set(try repository.loadMessages(conversationID: thread.local).map(\.id))
        var delivered: Set<UUID> = []
        var latest: Date?
        for message in page.messages {
            acknowledged.insert(message.id)
            if message.author == .you, message.delivered { delivered.insert(message.id) }
            if known.contains(message.id), let call = message.call {
                // A call's card gets what was said when the call ends.
                _ = try? repository.finishVoiceCall(messageID: message.id, conversationID: thread.local,
                                                    lines: callRecord(call).lines, endedAt: call.endedAt ?? Date())
                continue
            }
            guard !known.contains(message.id) else { continue }
            try await fetchMissing(message.attachments, into: thread)
            let author: MessageAuthor = switch message.author {
            case .you: .user
            // A bot since deleted on the Hub keeps its ID, as a deleted bot's messages do here.
            case .bot(let bot): .agent(entries.first { $0.remote == bot }?.agent ?? bot)
            case .system: .system
            }
            var copy = ChatMessage(id: message.id, conversationID: thread.local, author: author, body: message.body,
                                   createdAt: message.createdAt, delivery: message.delivered ? .delivered : .queued,
                                   attachmentIDs: message.attachments.map(\.id))
            copy.call = message.call.map(callRecord)
            try repository.append(copy)
            known.insert(message.id)
            latest = message.createdAt
        }
        if !delivered.isEmpty { try repository.markDelivered(conversationID: thread.local, messageIDs: delivered) }
        if let latest, var conversation = try repository.loadConversations().first(where: { $0.id == thread.local }) {
            conversation.updatedAt = max(conversation.updatedAt, latest)
            try repository.updateConversation(conversation)
        }
        // Delivery changes after the first read, so the last user message is read again until the bot
        // takes it, and a call's card until the call ends.
        let pendingFrom = page.messages.firstIndex { ($0.author == .you && !$0.delivered) || ($0.call != nil && $0.call?.endedAt == nil) }
        setSynced(pendingFrom.map { thread.synced + $0 } ?? thread.synced + page.messages.count, in: thread.remote)
        return page
    }

    private func callRecord(_ record: LinkCallRecord) -> VoiceCallRecord {
        VoiceCallRecord(agentID: entries.first { $0.remote == record.botID }?.agent ?? record.botID, endedAt: record.endedAt,
                        lines: record.lines.map { VoiceCallLine($0.speaker == .you ? .person : .bot, $0.text, at: $0.at) },
                        unanswered: record.unanswered.map { $0 == .declined ? .declined : .missed }, reason: record.reason)
    }

    private func setSynced(_ count: Int, in remote: UUID) {
        if let entry = entries.first(where: { $0.remoteConversation == remote }) {
            update(entry.remote) { $0.synced = count }
        } else if let index = groups.firstIndex(where: { $0.remote == remote }), groups[index].synced != count {
            groups[index].synced = count
            saveGroups()
        }
    }

    private func sendPending() async throws {
        for thread in threads {
            let waiting = try repository.loadMessages(conversationID: thread.local)
                .filter { $0.author == .user && $0.delivery == .queued && !acknowledged.contains($0.id) }
            guard !waiting.isEmpty else { continue }
            let files = Dictionary(try repository.loadAttachments(conversationID: thread.local).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            for message in waiting {
                // Files first: the Hub refuses a message that points at a file it lacks.
                for id in message.attachmentIDs ?? [] {
                    guard let file = files[id], file.url == nil else { continue }
                    try await pairing.upload(repository.attachmentFileURL(file), as: LinkAttachment(
                        id: file.id, filename: file.originalFilename, mediaType: file.mediaType, byteCount: Int(file.byteCount),
                        voice: file.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                          localeIdentifier: $0.localeIdentifier) },
                        annotation: file.annotation.map { LinkAnnotation($0) }),
                        to: thread.remote)
                }
                let sent = (message.attachmentIDs ?? []).filter { files[$0]?.url == nil }
                _ = try await pairing.request(.send(LinkOutgoingMessage(conversationID: thread.remote, id: message.id, body: message.body,
                                                    attachmentIDs: sent)))
                acknowledged.insert(message.id)
            }
        }
    }

    /// Lists the files of an incoming message that this copy lacks, keeping their IDs. Files come down
    /// when opened; voice messages and comments on files come at once, as their bubbles need them.
    private func fetchMissing(_ attachments: [LinkAttachment], into thread: Thread) async throws {
        guard !attachments.isEmpty else { return }
        let present = Set(try repository.loadAttachments(conversationID: thread.local).map(\.id))
        for attachment in attachments where !present.contains(attachment.id) {
            // A link travels as its address; one to something live keeps its card, and opens live here.
            if let url = attachment.url {
                // Pages leave card pictures out; each comes on its own.
                var image = attachment.card?.image
                if image == nil, attachment.card != nil,
                   case .picture(let picture)? = try? await pairing.request(.linkPreview(conversationID: thread.remote,
                                                                                         attachmentID: attachment.id)) {
                    image = picture
                }
                _ = try repository.importLinkAttachment(url, into: thread.local, card: attachment.card.map {
                    LinkCard(title: $0.title, detail: $0.detail, image: image, symbol: $0.symbol, colour: $0.colour,
                             icon: $0.icon, capturedAt: $0.capturedAt)
                }, id: attachment.id)
                continue
            }
            if attachment.voice == nil, attachment.annotation == nil {
                _ = try repository.recordAttachment(id: attachment.id, originalFilename: attachment.filename, into: thread.local,
                                                    mediaType: attachment.mediaType, byteCount: Int64(attachment.byteCount))
                continue
            }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-\(attachment.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await pairing.download(attachment, from: thread.remote, to: staging)
            let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let voice = attachment.voice.map {
                VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
            }
            let filename = name.isEmpty ? "Attachment" : name
            _ = try repository.importAttachment(from: staging, into: thread.local, mediaType: attachment.mediaType,
                                                voice: voice, annotation: attachment.annotation.map { AttachmentAnnotation($0) },
                                                id: attachment.id, originalFilename: filename)
        }
    }

    /// Pixels on the long side of the Hub's pictures of files, enough for a bubble in a large window.
    nonisolated public static let previewPixels = 1440
    /// How much room files downloaded from each Hub take on this Mac before the least recently opened go.
    nonisolated public static let keptFilesLimit: Int64 = 2 << 30

    /// Downloads and pictures under way, which everyone asking meanwhile waits for.
    @ObservationIgnored private var downloading: [UUID: Task<URL, Error>] = [:]
    @ObservationIgnored private var previewing: [UUID: Task<URL?, Error>] = [:]

    /// The file of an attachment here, downloaded from the Hub the first time it is opened. Files downloaded
    /// before go past `keptFilesLimit`, the least recently opened first; the Hub still has them.
    public func file(for attachment: ConversationAttachment) async throws -> URL {
        let url = repository.attachmentFileURL(attachment)
        if FileManager.default.fileExists(atPath: url.path) {
            // Notes it as just opened, so it is among the last to go past the limit.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        guard let thread = thread(local: attachment.conversationID) else { throw LinkError("That conversation is not on this Hub.") }
        if let download = downloading[attachment.id] { return try await download.value }
        let pairing = pairing, repository = repository, remote = thread.remote
        let download = Task<URL, Error> {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await pairing.download(LinkAttachment(id: attachment.id, filename: attachment.originalFilename,
                                                      mediaType: attachment.mediaType, byteCount: Int(attachment.byteCount)),
                                       from: remote, to: staging)
            return try repository.keepAttachmentFile(attachment, from: staging)
        }
        downloading[attachment.id] = download
        defer { downloading[attachment.id] = nil }
        let kept = try await download.value
        dropOldFiles(keeping: attachment.id)
        return kept
    }

    /// Whether an attachment here waits on the Hub to be opened, its contents not downloaded yet.
    public func isOnHubOnly(_ attachment: ConversationAttachment) -> Bool {
        Self.comesWhenOpened(attachment) && thread(local: attachment.conversationID) != nil
            && !FileManager.default.fileExists(atPath: repository.attachmentFileURL(attachment).path)
    }

    /// The Hub's picture of a picture, video or PDF here, so its bubble shows without the file coming down;
    /// kept beside the conversation's files. Nil when the Hub has nothing to show for it.
    public func preview(of attachment: ConversationAttachment) async throws -> URL? {
        if let kept = keptPreview(of: attachment) { return kept }
        guard Self.hasPreview(attachment), let thread = thread(local: attachment.conversationID) else { return nil }
        if let asking = previewing[attachment.id] { return try await asking.value }
        let pairing = pairing, remote = thread.remote, url = repository.attachmentPreviewURL(attachment, pixels: Self.previewPixels)
        let asking = Task<URL?, Error> {
            let request = LinkRequest.attachmentPreview(conversationID: remote, attachmentID: attachment.id, pixels: Self.previewPixels)
            guard case .picture(let data) = try await pairing.request(request) else { throw LinkError("The Hub sent an unexpected answer.") }
            guard let data else { return nil }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }
        previewing[attachment.id] = asking
        defer { previewing[attachment.id] = nil }
        return try await asking.value
    }

    /// The Hub's picture of a file here, when it was fetched before.
    public func keptPreview(of attachment: ConversationAttachment) -> URL? {
        let url = repository.attachmentPreviewURL(attachment, pixels: Self.previewPixels)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Drops the least recently opened files downloaded from the Hub past the limit; they come down
    /// again when opened. Files of messages the bot has not taken yet, and those still being written, stay.
    public func dropOldFiles(over limit: Int64 = HubMirror.keptFilesLimit, keeping kept: UUID? = nil) {
        var files: [(url: URL, size: Int64, opened: Date)] = []
        for thread in threads {
            guard let messages = try? repository.loadMessages(conversationID: thread.local),
                  let attachments = try? repository.loadAttachments(conversationID: thread.local) else { continue }
            let waiting = Set(messages.filter { $0.author == .user && $0.delivery == .queued }.flatMap { $0.attachmentIDs ?? [] })
            let sent = Set(messages.flatMap { $0.attachmentIDs ?? [] }).subtracting(waiting)
            for attachment in attachments where attachment.id != kept && sent.contains(attachment.id) && Self.comesWhenOpened(attachment) {
                let url = repository.attachmentFileURL(attachment)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                files.append((url, Int64(size), values.contentModificationDate ?? .distantPast))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.opened < $1.opened }) where total > limit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// Files, not links, voice messages or comments on files, which come with their messages.
    private static func comesWhenOpened(_ attachment: ConversationAttachment) -> Bool {
        attachment.url == nil && attachment.voice == nil && attachment.annotation == nil
    }

    /// What the Hub makes pictures of.
    private static func hasPreview(_ attachment: ConversationAttachment) -> Bool {
        attachment.mediaType.hasPrefix("image/") || attachment.mediaType.hasPrefix("video/") || attachment.mediaType == "application/pdf"
    }

    /// Makes the local stand-in for a bot on the Hub.
    private func adopt(_ bot: LinkBot) throws -> AgentRecord {
        let draft = bot.draft
        let created = try repository.createAgent(
            named: draft.name, harnessIdentifier: draft.provider, modelIdentifier: draft.model,
            reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
            avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
            avatarImageData: draft.avatarImageData, backstory: draft.backstory)
        entries.append(Entry(remote: bot.id, remoteConversation: bot.conversationID, agent: created.agent.id,
                             conversation: created.conversation.id, synced: 0, profile: draft.profile, owner: bot.owner,
                             sharedWith: bot.sharedWith, canCall: bot.canCall, pinnedAt: bot.pinnedAt,
                             imageGeneration: draft.imageGeneration))
        save()
        var agent = created.agent
        // Shown in the bot's editor here; the Hub calls with it.
        if let voice = draft.voice { try repository.updateAgentVoice(agent, voice: voice) }
        if let archivedAt = bot.archivedAt { agent = try repository.setAgentArchived(true, agentID: agent.id, now: archivedAt) }
        // The Hub checked it when the bot set it.
        guard let status = bot.status, let withStatus = try? repository.setAgentStatus(status, agentID: agent.id) else {
            return agent
        }
        return withStatus
    }

    private func apply(_ bot: LinkBot, to entry: Entry) throws {
        guard let agent = try repository.loadAgents().first(where: { $0.id == entry.agent }) else { return }
        if agent.status != bot.status, (try? repository.setAgentStatus(bot.status, agentID: agent.id)) != nil { onChange?() }
        if (agent.archivedAt != nil) != (bot.archivedAt != nil) {
            try repository.setAgentArchived(bot.archivedAt != nil, agentID: agent.id, now: bot.archivedAt ?? Date())
            onChange?()
        }
        var draft = bot.draft
        // A picture that could not be fetched yet keeps the one here.
        if draft.avatarImageData == nil, draft.avatarImageDigest != nil { draft.avatarImageData = agent.avatarImageData }
        update(entry.remote) {
            $0.profile = draft.profile
            $0.owner = bot.owner
            $0.sharedWith = bot.sharedWith
            $0.canCall = bot.canCall
            $0.pinnedAt = bot.pinnedAt
            $0.imageGeneration = draft.imageGeneration
        }
        let unchanged = agent.displayName == draft.name && agent.harnessIdentifier == draft.provider
            && agent.modelIdentifier == draft.model && agent.reasoningEffort == draft.reasoningEffort
            && (agent.publicDescription ?? "") == draft.publicDescription && agent.avatarSymbolName == draft.avatarSymbolName
            && agent.avatarColorIndex == draft.avatarColorIndex && agent.avatarImageData == draft.avatarImageData
        if !unchanged {
            _ = try repository.updateAgent(
                agent, displayName: draft.name, harnessIdentifier: draft.provider, modelIdentifier: draft.model,
                reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
                avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
                avatarImageData: draft.avatarImageData)
            onChange?()
        }
        if try repository.loadAgentBackstory(agent) != draft.backstory {
            try repository.updateAgentBackstory(agent, backstory: draft.backstory)
        }
        try repository.updateAgentVoice(agent, voice: draft.voice)
    }

    private func forget(_ entry: Entry) throws {
        if let agent = try repository.loadAgents().first(where: { $0.id == entry.agent }) {
            try repository.deleteAgent(agent)
        }
        entries.removeAll { $0.remote == entry.remote }
        save()
    }

    /// Makes the local copy of a group on the Hub, of its bots' stand-ins here.
    private func adopt(_ group: LinkGroup) throws -> BotConversation {
        let conversation = try repository.createGroup(named: group.draft.name, publicDescription: group.draft.publicDescription,
                                                      participantIDs: localAgents(group.draft.botIDs),
                                                      existingAgents: try repository.loadAgents())
        groups.append(GroupEntry(remote: group.id, conversation: conversation.id, synced: 0, pinnedAt: group.pinnedAt,
                                 notifications: group.notifications))
        saveGroups()
        guard let archivedAt = group.archivedAt else { return conversation }
        return try repository.setConversationArchived(true, conversationID: conversation.id, now: archivedAt)
    }

    /// Copies a group's name, description, bots and whether it is archived. The notice Group Info leaves comes from the Hub with its messages.
    @discardableResult private func apply(_ group: LinkGroup, to entry: GroupEntry) throws -> Bool {
        guard var conversation = try repository.loadConversations().first(where: { $0.id == entry.conversation }) else { return false }
        let bots = localAgents(group.draft.botIDs).sorted { $0.uuidString < $1.uuidString }
        let description = group.draft.publicDescription.isEmpty ? nil : group.draft.publicDescription
        let archivedChanged = (conversation.archivedAt != nil) != (group.archivedAt != nil)
        guard conversation.displayName != group.draft.name || conversation.publicDescription != description
                || conversation.participantIDs != bots || archivedChanged else { return false }
        conversation.displayName = group.draft.name
        conversation.publicDescription = description
        conversation.participantIDs = bots
        if archivedChanged { conversation.archivedAt = group.archivedAt }
        try repository.updateConversation(conversation)
        return true
    }

    private func localAgents(_ bots: [UUID]) -> [UUID] {
        bots.compactMap { id in entries.first { $0.remote == id }?.agent }
    }

    private func forget(_ group: GroupEntry) throws {
        if FileManager.default.fileExists(atPath: repository.conversationDirectory(id: group.conversation).path) {
            try repository.deleteConversation(id: group.conversation)
        }
        groups.removeAll { $0.remote == group.remote }
        saveGroups()
    }

    private func saveGroups() {
        try? FileManager.default.createDirectory(at: groupsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(groups).write(to: groupsURL, options: .atomic)
    }

    private func update(_ remote: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.remote == remote }) else { return }
        let before = entries[index]
        change(&entries[index])
        if entries[index] != before { save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

@MainActor extension Array where Element == HubMirror {
    /// A bot on this Mac's sharing on each of these Hubs, asked of all at once, in their order. A Hub that does
    /// not answer in time, and whose people are not kept here, is left out.
    public func sharing(of agent: UUID) async -> [LinkHubSharing] {
        await withTaskGroup(of: (Int, LinkHubSharing?).self) { group in
            for (index, hub) in enumerated() {
                group.addTask { (index, try? await hub.sharing(of: agent)) }
            }
            var found: [(Int, LinkHubSharing)] = []
            for await (index, sharing) in group { if let sharing { found.append((index, sharing)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Shares a bot on this Mac with exactly `people` on the one of these Hubs that goes by `id` for this Mac's devices.
    public func share(_ agent: AgentRecord, onHub id: String, with people: [UUID]) async throws {
        guard let hub = first(where: { $0.sharingID == id }) else { throw LinkError("That Hub is not one this Mac can share the bot on.") }
        try await hub.hosting.share(agent, with: people)
    }
}

/// Resumes once, with whichever answer comes first.
@MainActor private final class FirstAnswer<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func answer(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// A harness a joined Hub lends, as the bot editor's harness selection holds it.
public struct HubHarnessChoice: Equatable, Sendable {
    private static let prefix = "hub|"

    public var hub: LinkPublicKey?
    public var provider: String
    public var profile: UUID?

    public init(hub: LinkPublicKey?, provider: String, profile: UUID?) {
        self.hub = hub
        self.provider = provider
        self.profile = profile
    }

    public var identifier: String {
        Self.prefix + [hub?.x963.base64EncodedString() ?? "", provider, profile?.uuidString ?? ""].joined(separator: "|")
    }

    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        let parts = identifier.dropFirst(Self.prefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let key = Data(base64Encoded: parts[0]), let hub = try? LinkPublicKey(x963: key) else { return nil }
        self.init(hub: hub, provider: parts[1], profile: UUID(uuidString: parts[2]))
    }
}

extension LinkConnection {
    /// As this Mac shows a connection, with the Hub's icon.
    public var record: MCPConnectionRecord? {
        var record = try? MCPConnectionRecord(id: draft.id, name: draft.name, endpoint: draft.endpoint,
                                              description: draft.description, instructions: draft.instructions)
        record?.iconData = iconData
        return record
    }
}

extension LinkConnectionDraft {
    public init(_ record: MCPConnectionRecord) {
        self.init(id: record.id, name: record.name, endpoint: record.endpoint,
                  description: record.description, instructions: record.instructions)
    }
}

// As HubCore has them, which this module does not depend on.
extension LinkAnnotation {
    init(_ annotation: AttachmentAnnotation) {
        self.init(version: annotation.version, sourceAttachmentID: annotation.sourceAttachmentID,
                  sourceFilename: annotation.sourceFilename, sourceMessageID: annotation.sourceMessageID, quote: annotation.quote,
                  comment: annotation.comment, region: annotation.region.map { Region(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    }
}

extension AttachmentAnnotation {
    /// Checked when the file it came with is kept.
    init(_ link: LinkAnnotation) {
        self.init(version: link.version, sourceAttachmentID: link.sourceAttachmentID, sourceFilename: link.sourceFilename,
                  sourceMessageID: link.sourceMessageID, quote: link.quote, comment: link.comment,
                  region: link.region.map { Region(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    }
}
