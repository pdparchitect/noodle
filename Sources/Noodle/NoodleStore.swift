import AppKit
import Foundation
import HubLink
import Observation
import NoodleAppletTools
import NoodleCalendarTools
import NoodleCore
import NoodleHubClient
import NoodleRemindersTools
import UniformTypeIdentifiers
import NoodleRuntime
import NoodleRuntimeSettings

private struct TranscriptSnapshot: Sendable {
    let conversations: [BotConversation]
    let messages: [UUID: [ChatMessage]]
    let attachments: [UUID: [ConversationAttachment]]
    let conversationsChanged: Bool
    let messagesChanged: Bool
    let attachmentsChanged: Bool
    let revisions: [UUID: TranscriptRevision]
}

private struct TranscriptRevision: Equatable, Sendable {
    let messagesModifiedAt: Date?
    let messagesSize: UInt64?
    let attachmentsModifiedAt: Date?
}

@MainActor
@Observable
final class NoodleStore {
    private(set) static var active: NoodleStore?

    enum CreationSheet: Identifiable {
        case bot
        case group

        var id: String {
            switch self {
            case .bot: return "bot"
            case .group: return "group"
            }
        }
    }

    private(set) var agents: [AgentRecord] = []
    private(set) var conversations: [BotConversation] = []
    private(set) var messagesByConversation: [UUID: [ChatMessage]] = [:] {
        didSet { transcriptGeneration &+= 1 }
    }
    private(set) var attachmentsByConversation: [UUID: [ConversationAttachment]] = [:] {
        didSet {
            transcriptGeneration &+= 1
            attachmentLookupByConversation = attachmentsByConversation.mapValues { attachments in
                Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
            }
        }
    }
    private(set) var pinnedConversationIDs: [UUID] = []
    /// The space the sidebar shows: a joined Hub's by its key, so it is kept when the Hub is left and joined again,
    /// or one the person made by its ID; nil shows All.
    private(set) var space: String? = UserDefaults.standard.string(forKey: NoodleStore.spaceKey)
    static let spaceKey = "Noodle.space"
    /// The spaces the person made, in Noodle's own folder.
    @ObservationIgnored private(set) lazy var spaceList = SpaceList(file: repository.rootURL.appendingPathComponent("spaces.json"))
    var customSpaces: [CustomSpace] { spaceList.spaces }
    /// Carries them to the person's other devices through iCloud, in builds signed for it.
    @ObservationIgnored private var spaceSync: SpaceCloudSync?

    /// A new space, starting with the bot or group it was made from, or a new name for one.
    enum SpaceNaming: Equatable {
        case new(adding: UUID?)
        case rename(CustomSpace)
    }
    private(set) var unreadConversationIDs: Set<UUID> = [] {
        didSet { updateDockBadge() }
    }
    var selectedConversationID: UUID?
    var searchText = ""
    private var drafts = ConversationDrafts()
    var draft: String {
        get { selectedConversationID.map { drafts[$0].text } ?? "" }
        set {
            guard let selectedConversationID else { return }
            setDraft(newValue, for: selectedConversationID)
        }
    }

    func draft(for conversationID: UUID) -> String {
        drafts[conversationID].text
    }

    func setDraft(_ text: String, for conversationID: UUID) {
        drafts[conversationID].text = text
        markConversationRead(conversationID)
    }

    /// Empties the composer, both what was written and what was attached to it.
    func clearDraft(for conversationID: UUID) {
        drafts.clear(conversationID)
    }
    var creationSheet: CreationSheet?
    /// The first launch's full-window welcome, which ends in setting up the first bot.
    var showsWelcome = false
    /// Help > Connect, in the main window as the welcome is: reaching this Mac from other devices, or sharing with other people.
    var showsConnect = false
    var selectedSettingsTab: NoodleSettingsTab = .general
    var agentBeingEdited: AgentRecord?
    var groupBeingEdited: BotConversation?
    var backgroundBeingEdited: BotConversation?
    var spaceNaming: SpaceNaming?
    var spaceBeingDeleted: CustomSpace?
    private(set) var backgrounds: [UUID: ConversationBackground] = [:]
    var errorMessage: String?
    private(set) var storageReady = false
    var pendingAttachments: [ConversationAttachment] {
        get { selectedConversationID.map { drafts[$0].attachments } ?? [] }
        set {
            guard let selectedConversationID else { return }
            drafts[selectedConversationID].attachments = newValue
        }
    }
    func pendingAttachments(for conversationID: UUID) -> [ConversationAttachment] {
        drafts[conversationID].attachments
    }
    let conversationWindows: ConversationWindowRegistry
    let activityWindows = AgentActivityWindows()
    @ObservationIgnored private var voiceRecorders: [UUID: AnyObject] = [:]

    func voiceRecorder(for conversationID: UUID) -> VoiceRecorder {
        if let recorder = voiceRecorders[conversationID] as? VoiceRecorder { return recorder }
        let recorder = VoiceRecorder(directory: repository.attachmentsDirectory(conversationID: conversationID)
            .appendingPathComponent("VoiceDraft", isDirectory: true))
        voiceRecorders[conversationID] = recorder
        return recorder
    }

    let repository: WorkspaceRepository
    @ObservationIgnored private let transcriptPositions: TranscriptPositionStore
    let messenger: MessengerBroker
    /// Every source of agent tools registers here; `messenger tool` reaches them through `tools`.
    let toolProviders = ToolProviderRegistry()
    let tools: ToolBridgeBroker
    /// What each bot is assigned, as the tool broker enforces it. Controllers publish into it.
    @ObservationIgnored private let toolAssignments: ToolAssignmentStore
    @ObservationIgnored private let toolHost: ToolHostServices
    @ObservationIgnored private lazy var toolExtensions = ToolExtensionDiscovery(registry: toolProviders)
    let mcp: MCPController
    let computers: ComputerController
    let browsers: BrowserController
    let calendars: EventKitController
    let reminders: EventKitController
    let applets: AppletController
    let harnessProfiles: HarnessProfilesController
    let runtime: AgentRuntimeCoordinator
    let usage: UsageHistory
    /// The Noodle Hubs this Mac joined.
    let hubs: HubMemberships
    /// This Mac serving its owner's devices, as a Noodle Hub of its own.
    let thisMac: ThisMacHub
    /// An invitation opened from a link, waiting in Settings > Hub to be joined.
    var pendingHubInvitation: String?
    /// This Mac's copy of the bots it keeps on each joined Hub.
    private(set) var hubMirrors: [HubMirror] = []
    /// Live views of what Hub bots' links point at.
    @ObservationIgnored let surfacePanels = HubSurfacePanels()
    /// Noodlets opened from conversations, annotated in place from Noodle Applet.
    @ObservationIgnored let noodletAnnotations: NoodletAnnotations
    @ObservationIgnored private let noodletOverlay = NoodletAnnotationOverlay()
    @ObservationIgnored private var hubMirrorTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    let harnessSetup: HarnessSetupController
    private let connectsServices: Bool
    private var transcriptRefreshTask: Task<Void, Never>?
    private var harnessUpdateTask: Task<Void, Never>?
    private var hubCheckInTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptGeneration: UInt = 0
    private var attachmentLookupByConversation: [UUID: [UUID: ConversationAttachment]] = [:]
    @ObservationIgnored private var transcriptRevisions: [UUID: TranscriptRevision] = [:]
    private var isProcessingShares = false
    private var failedShareIDs: Set<UUID> = []

    init(repository: WorkspaceRepository? = nil, runtime: AgentRuntimeCoordinator? = nil, connectsServices: Bool = true) {
        self.connectsServices = connectsServices
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let repository {
            self.repository = repository
        } else {
            let bundledMessenger = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/messenger")
            self.repository = WorkspaceRepository(
                rootURL: HarnessStorage.dataRoot(applicationSupport: applicationSupport),
                launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                    ? bundledMessenger
                    : Bundle.main.executableURL
            )

        }
        if let runtime {
            self.runtime = runtime
        } else {
            var environment = ProcessInfo.processInfo.environment
            #if NOODLE_DEV_HOOKS
            // A rehearsal also hides harnesses installed outside the home it gives them.
            if Rehearsal.folder(in: applicationSupport) != nil {
                environment["NOODLE_SIMULATE_NO_HARNESSES"] = "1"
            }
            #endif
            // Only the app's own storage holds harnesses the Agent Host will trust.
            let discovery = HarnessDiscovery(managedHarnesses: repository == nil ? self.repository.managedHarnesses : nil,
                                             environment: environment)
            discovery.removeSupersededManagedHarnesses()
            self.runtime = AgentRuntimeCoordinator(discovery: discovery)
        }
        self.runtime.remoteModels = RemoteModelAccountStore(repository: self.repository.rootURL)
        usage = UsageHistory(url: self.repository.rootURL.appendingPathComponent("usage.sqlite"))
        self.runtime.onUsage = { [usage] in usage.record($0) }
        self.runtime.recordedUsage = { [usage] in usage.recorded(session: $0) }
        hubs = HubMemberships(directory: self.repository.rootURL.appendingPathComponent("Hubs", isDirectory: true),
                              deviceName: Host.current().localizedName ?? "Mac")
        harnessSetup = HarnessSetupController(versionChecker: HarnessVersionChecker(),
            installer: repository == nil ? ManagedHarnessInstaller(store: self.repository.managedHarnesses) : nil)

        transcriptPositions = TranscriptPositionStore(fileURL: self.repository.rootURL.appendingPathComponent("scroll-positions.json"))
        conversationWindows = ConversationWindowRegistry(fileURL: self.repository.rootURL.appendingPathComponent("conversation-windows.json"))
        messenger = MessengerBroker(repository: self.repository)
        let toolAssignments = ToolAssignmentStore()
        self.toolAssignments = toolAssignments
        // The broker exists before the controllers, so revocations reach them through this box.
        let revocations = ToolRevocations()
        let toolHost = ToolHostServices.repository(self.repository, revoked: { revocations.handle($0, $1, $2) }) { toolAssignments.assignments(for: $0) }
        self.toolHost = toolHost
        tools = ToolBridgeBroker(registry: toolProviders, host: toolHost) { toolAssignments.assignments(for: $0) }
        mcp = MCPController(repository: self.repository)
        mcp.toolRegistry = toolProviders
        mcp.onAssignmentsChange = { [toolAssignments, tools] granted in
            toolAssignments.replace(ConnectionToolProvider.grantKind, with: granted)
            tools.synchronizeSkills()
        }
        computers = ComputerController(repository: self.repository)
        computers.onAssignmentsChange = { [toolAssignments, tools] assigned in
            toolAssignments.replace("computer", with: assigned)
            tools.synchronizeSkills()
        }
        revocations.handler = { [computers] kind, id, agent in
            guard kind == "computer", let computer = UUID(uuidString: id) else { return }
            Task { @MainActor in computers.revoke(computer: computer, agent: agent) }
        }
        browsers = BrowserController(repository: self.repository)
        browsers.onAssignmentsChange = { [toolAssignments, tools] assigned in
            toolAssignments.replace("browser", with: assigned)
            tools.synchronizeSkills()
        }
        // Calendar and Reminders are the providers Noodle hosts itself: macOS grants this
        // access to the app the person sees, never to a tool extension. See Tools/AGENTS.md.
        let calendarStore = EventKitCalendarStore(), reminderStore = EventKitReminderStore()
        calendars = EventKitController(repository: self.repository, kind: .calendar) { try await calendarStore.calendars() }
        reminders = EventKitController(repository: self.repository, kind: .reminderList) { try await reminderStore.lists() }
        for controller in [calendars, reminders] {
            controller.onAssignmentsChange = { [toolAssignments, tools, kind = controller.kind] assigned in
                toolAssignments.replace(kind.rawValue, with: assigned)
                tools.synchronizeSkills()
            }
        }
        try? toolProviders.register(CalendarToolProvider(store: calendarStore))
        try? toolProviders.register(ReminderToolProvider(store: reminderStore))
        applets = AppletController()
        applets.onGrantsChange = { [toolAssignments, tools] granted in
            toolAssignments.replace(AppletToolGrant.kind, with: granted)
            tools.synchronizeSkills()
        }
        try? toolProviders.register(AppletToolProvider { [applets] in try await applets.tool($0) })
        noodletAnnotations = NoodletAnnotations(applets: applets)
        harnessProfiles = HarnessProfilesController(store: self.repository.harnessProfiles)
        thisMac = ThisMacHub(repository: self.repository, runtime: self.runtime, applets: applets, profiles: harnessProfiles,
                             service: mcp.service)
        // Before any bot starts, so bots on a Hub never run here.
        refreshHubMirrors()
        reload()
        // A device made, changed or deleted one of this Mac's bots.
        messenger.onAgentChanged = { [weak self] id in Task { @MainActor in self?.reloadStatus(of: id) } }
        messenger.noodletHasPreview = { [applets] url in await applets.hasPreview(url) }
        thisMac.onBotsEdited = { [weak self] in self?.reload() }
        noodletAnnotations.present = { [weak self] capture in
            self?.noodletOverlay.present(capture) { note, content, source, raw in
                try self?.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }
        }
        thisMac.onRead = { [weak self] in self?.readElsewhere($0, upTo: $1) }
        thisMac.onBackgroundChanged = { [weak self] in self?.reloadBackground(of: $0) }
        // A device changed this Mac's tools, computers or browsers, in the files these controllers keep.
        thisMac.onToolsEdited = { [weak self] in self?.reloadToolsEditedElsewhere() }
        thisMac.onPinsEdited = { [weak self] in self?.reloadPins() }
        // The owner's phone shares this Mac's bots through the Hubs it joined.
        thisMac.hubSharing = { [weak self] id in await self?.hubSharing(ofAgent: id) ?? [] }
        thisMac.shareOnHub = { [weak self] id, hub, people in
            guard let self else { return [] }
            try await self.share(agentID: id, onHub: hub, with: people)
            return await self.hubSharing(ofAgent: id)
        }
        self.runtime.onSignInRequired = { [weak self] id in
            guard let self, self.connectsServices, let agent = self.agents.first(where: { $0.id == id }) else { return }
            NoodleNotifications.postSignInRequired(for: agent)
        }
        if connectsServices {
            spaceSync = SpaceCloudSync.ifEntitled(list: spaceList, stateFile: self.repository.rootURL.appendingPathComponent("spaces-sync.json"))
        }
        Self.active = self
    }

    /// The Mac hears of iCloud changes only when it asks, so it asks whenever Noodle comes to the front.
    func fetchSpaces() {
        guard let spaceSync else { return }
        Task { await spaceSync.fetch() }
    }

    var selectedConversation: BotConversation? {
        conversations.first(where: { $0.id == selectedConversationID })
    }

    var canCreateBot: Bool {
        storageReady && (!runtime.availableInstallations.isEmpty || hubs.hubs.contains { $0.status?.harnesses.isEmpty == false })
    }

    /// The welcome, once, for someone with no bots yet. Afterwards the empty window and Help > Welcome offer it.
    func offerFirstBotSetup(defaults: UserDefaults = .standard) {
        guard storageReady, agents.isEmpty, !defaults.bool(forKey: FirstBotSetup.dismissedKey) else { return }
        showsWelcome = true
    }

    /// Help > Welcome: the welcome again, bots or not.
    func showWelcome() {
        showsConnect = false
        showsWelcome = true
    }

    func showConnect() {
        showsWelcome = false
        showsConnect = true
    }

    /// Connecting to this Mac is set up in Settings > Hub.
    func connectThisMac() {
        showsConnect = false
        selectedSettingsTab = .hub
    }

    func finishFirstBotSetup(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: FirstBotSetup.dismissedKey)
        showsWelcome = false
    }

    func showNewBot() {
        guard canCreateBot else { return }
        creationSheet = .bot
    }

    /// The Hub whose space is shown, while it is still joined; nil for All and the spaces the person made.
    var spaceMirror: HubMirror? {
        space.flatMap { key in hubMirrors.first { Self.spaceKey(of: $0) == key } }
    }

    /// The space the person made that is shown; nil for All and the Hubs' spaces.
    var shownCustomSpace: CustomSpace? {
        space.flatMap { id in customSpaces.first { $0.id.uuidString == id } }
    }

    /// Neither a joined Hub's space, this Mac's nor one the person made, including one left or deleted elsewhere.
    var isShowingAll: Bool { spaceMirror == nil && shownCustomSpace == nil && !showsThisMac }

    /// Only the bots and groups kept on this Mac; with no Hub joined, that is All.
    var showsThisMac: Bool { space == Self.thisMacSpace && !hubMirrors.isEmpty }
    private static let thisMacSpace = "this-mac"

    func showThisMac() {
        setSpace(Self.thisMacSpace)
    }

    func showSpace(_ mirror: HubMirror?) {
        setSpace(mirror.flatMap(Self.spaceKey(of:)))
    }

    func showSpace(custom id: UUID) {
        setSpace(id.uuidString)
    }

    private func setSpace(_ space: String?) {
        self.space = space
        UserDefaults.standard.set(space, forKey: Self.spaceKey)
    }

    private static func spaceKey(of mirror: HubMirror) -> String? { mirror.pairing.hub?.key.x963.base64EncodedString() }

    /// Makes a space and shows it.
    @discardableResult
    func addSpace(named name: String) -> CustomSpace? {
        guard let created = changeSpaces({ try spaceList.add(named: name) }) else { return nil }
        showSpace(custom: created.id)
        return created
    }

    func renameSpace(_ id: UUID, to name: String) {
        changeSpaces { try spaceList.rename(id, to: name) }
    }

    /// Only the space goes; its bots and groups stay where they are.
    func deleteSpace(_ id: UUID) {
        changeSpaces { try spaceList.delete(id) }
        if shownCustomSpace == nil, spaceMirror == nil { setSpace(nil) }
    }

    func isMember(_ conversationID: UUID, of spaceID: UUID) -> Bool {
        spaceList.space(spaceID).flatMap { heldMember(for: conversationID, in: $0) } != nil
    }

    func setMember(_ isMember: Bool, of spaceID: UUID, conversationID: UUID) {
        guard let space = spaceList.space(spaceID) else { return }
        let held = heldMember(for: conversationID, in: space)
        guard isMember != (held != nil) else { return }
        changeSpaces { try spaceList.setMember(isMember, held ?? spaceMember(for: conversationID), of: spaceID) }
    }

    @discardableResult
    private func changeSpaces<T>(_ change: () throws -> T) -> T? {
        do { return try change() } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A bot or group made while a space the person made is shown joins it, so it shows there.
    private func joinShownSpace(_ conversationID: UUID?) {
        guard let conversationID, let space = shownCustomSpace else { return }
        setMember(true, of: space.id, conversationID: conversationID)
    }

    /// A Hub's bots and groups by the Hub's key and their conversation there, so the person's other devices find them too.
    private func spaceMember(for conversationID: UUID) -> CustomSpace.Member {
        if let mirror = hubMirror(forConversation: conversationID), let key = Self.spaceKey(of: mirror),
           let remote = mirror.remoteConversation(local: conversationID) {
            return CustomSpace.Member(hub: key, conversation: remote)
        }
        return CustomSpace.Member(hub: thisMac.key, conversation: conversationID)
    }

    /// The member a space holds for the conversation, however it was named: this Mac's own may be named by
    /// this Mac's key or, from before it served any device, by none.
    private func heldMember(for conversationID: UUID, in space: CustomSpace) -> CustomSpace.Member? {
        space.members.first { self.conversationID(of: $0) == conversationID }
    }

    /// The local conversation a member names, while its Hub is joined.
    private func conversationID(of member: CustomSpace.Member) -> UUID? {
        guard let hub = member.hub, hub != thisMac.key else { return member.conversation }
        return hubMirrors.first { Self.spaceKey(of: $0) == hub }?.localConversation(remote: member.conversation)
    }

    /// The harness New Bot starts on: in a Hub's space, the first that Hub lends, so the bot shows there.
    /// Nil in All, for one on this Mac. Either way the person can choose another.
    var spaceHarnessIdentifier: String? {
        guard let pairing = spaceMirror?.pairing, let hub = pairing.hub, let lent = pairing.status?.harnesses.first else { return nil }
        return HubHarnessChoice(hub: hub.key, provider: lent.provider, profile: lent.profile).identifier
    }

    /// Where New Group starts: the Hub whose space is shown, unless it starts with bots that are not that Hub's.
    func groupCreationHub(participantIDs: Set<UUID>) -> HubMirror? {
        guard let mirror = spaceMirror, participantIDs.isSubset(of: mirror.localAgentIDs) else { return nil }
        return mirror
    }

    /// All's pins are this Mac's own, and This Mac shows them too; a Hub's space shows the pins the Hub keeps
    /// for every device, and a space the person made its own.
    private var shownPinnedIDs: [UUID] {
        if let custom = shownCustomSpace { return custom.pins.compactMap(conversationID(of:)) }
        return spaceMirror?.pinnedConversations ?? pinnedConversationIDs
    }

    /// The conversations the shown space holds; nil in All.
    private var shownSpaceConversationIDs: Set<UUID>? {
        if let custom = shownCustomSpace { return Set(custom.members.compactMap(conversationID(of:))) }
        if showsThisMac { return Set(conversations.map(\.id)).subtracting(hubMirrors.flatMap(\.localConversationIDs)) }
        return spaceMirror.map { Set($0.localConversationIDs) }
    }

    var filteredConversations: [BotConversation] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = shownSpaceConversationIDs
        let conversations = conversations.filter { !isArchived($0) && space?.contains($0.id) != false }
        guard !term.isEmpty else { return conversations }

        return conversations.filter { conversation in
            title(for: conversation).localizedCaseInsensitiveContains(term) ||
                (conversation.publicDescription?.localizedCaseInsensitiveContains(term) ?? false) ||
                participants(for: conversation).contains {
                    $0.displayName.localizedCaseInsensitiveContains(term)
                } ||
                messages(for: conversation).contains {
                    $0.body.localizedCaseInsensitiveContains(term)
                }
        }
    }

    /// Pinned bots and groups sit above the rest, in the order they were pinned.
    var pinnedConversations: [BotConversation] {
        let visible = Dictionary(uniqueKeysWithValues: filteredConversations.map { ($0.id, $0) })
        return shownPinnedIDs.compactMap { visible[$0] }
    }

    var directConversations: [BotConversation] {
        let pinned = shownPinnedIDs
        return filteredConversations.filter { $0.kind == .direct && !pinned.contains($0.id) }
    }

    var groupConversations: [BotConversation] {
        let pinned = shownPinnedIDs
        return filteredConversations.filter { $0.kind == .group && !pinned.contains($0.id) }
    }

    func isPinned(_ conversationID: UUID) -> Bool {
        shownPinnedIDs.contains(conversationID)
    }

    func setPinned(_ pinned: Bool, conversationID: UUID) {
        guard pinned != isPinned(conversationID) else { return }
        if let custom = shownCustomSpace {
            guard let member = heldMember(for: conversationID, in: custom) else { return }
            changeSpaces { try spaceList.setPinned(pinned, member, in: custom.id) }
            return
        }
        if let mirror = spaceMirror {
            Task {
                do { try await mirror.setPinned(pinned, conversation: conversationID) }
                catch { errorMessage = error.localizedDescription }
            }
            return
        }
        var updated = pinnedConversationIDs.filter { $0 != conversationID }
        if pinned { updated.append(conversationID) }
        do {
            try repository.savePinnedConversationIDs(updated)
            pinnedConversationIDs = updated
            thisMac.hub?.pinsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The owner pinned on another of their devices, through This Mac as a Hub.
    private func reloadPins() {
        let known = Set(conversations.map(\.id))
        pinnedConversationIDs = ((try? repository.loadPinnedConversationIDs()) ?? []).filter(known.contains)
    }

    func reload() {
        storageReady = false
        do {
            try repository.prepare()
            agents = try repository.loadAgents()
            runtime.archivedAgentIDs = Set(agents.filter { $0.archivedAt != nil }.map(\.id))
            activityWindows.synchronize(agents: agents)
            runtime.reloadAccess()
            try repository.synchronizeAgentWorkspaces(agents)
            if connectsServices {
                try messenger.start(agents: agents)
                // Provider skills appear after discovery; a bot's AGENTS.md lists them once they do.
                tools.onSkillsChanged = { [weak self] id in
                    Task { @MainActor in
                        guard let self, let agent = self.agents.first(where: { $0.id == id }) else { return }
                        try? self.repository.synchronizeAgentWorkspace(agent)
                    }
                }
                try tools.start(agents: toolAgents)
                toolExtensions.start()
                mcp.start(agents: agents)
                computers.start(agents: agents)
                browsers.start(agents: agents)
                applets.start(agents: agents)
            }
            conversations = try repository.loadConversations().filter(\.isShownHere)
            backgrounds = Dictionary(uniqueKeysWithValues: conversations.map {
                ($0.id, (try? repository.loadBackground(conversationID: $0.id)) ?? ConversationBackground())
            })
            messagesByConversation = try Dictionary(
                uniqueKeysWithValues: conversations.map {
                    ($0.id, try repository.loadMessages(conversationID: $0.id))
                }
            )
            attachmentsByConversation = try Dictionary(
                uniqueKeysWithValues: conversations.map {
                    ($0.id, try repository.loadAttachments(conversationID: $0.id))
                }
            )
            transcriptRevisions = Dictionary(uniqueKeysWithValues: conversations.map {
                ($0.id, Self.transcriptRevision(for: $0.id, repository: repository))
            })
            for conversation in conversations {
                drafts.restoreAnnotations(attachmentsByConversation[conversation.id, default: []],
                    messages: messagesByConversation[conversation.id, default: []], conversationID: conversation.id)
            }
            let knownConversationIDs = Set(conversations.map(\.id))
            drafts.retainConversations(knownConversationIDs)
            try? transcriptPositions.retainConversations(knownConversationIDs)
            conversationWindows.retainConversations(knownConversationIDs)
            let storedPinnedIDs = try repository.loadPinnedConversationIDs()
            pinnedConversationIDs = storedPinnedIDs.filter(knownConversationIDs.contains)
            if pinnedConversationIDs != storedPinnedIDs {
                try repository.savePinnedConversationIDs(pinnedConversationIDs)
                thisMac.hub?.pinsChanged()
            }
            // Members out of reach stay stored, so a space is never pruned here.
            spaceList.reload()
            let storedUnreadIDs = try repository.loadUnreadConversationIDs()
            unreadConversationIDs = storedUnreadIDs.intersection(knownConversationIDs)
            if unreadConversationIDs != storedUnreadIDs {
                try repository.saveUnreadConversationIDs(unreadConversationIDs)
            }
            runtime.refresh(agents: agents)
            refreshAppShortcuts()
            storageReady = true

            if let selectedConversationID,
               conversations.contains(where: { $0.id == selectedConversationID }) {
                return
            }
            selectedConversationID = conversations.first { !isArchived($0) }?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bots that are not archived, the ones a message or a new group can reach.
    var activeAgents: [AgentRecord] { agents.filter { $0.archivedAt == nil } }

    var archivedGroups: [BotConversation] {
        conversations.filter { $0.kind == .group && $0.archivedAt != nil }
    }

    /// A group is archived itself; a bot's direct conversation follows its bot.
    /// Views may hold an older copy, so the current one decides.
    func isArchived(_ conversation: BotConversation) -> Bool {
        let conversation = current(conversation)
        if conversation.kind == .group { return conversation.archivedAt != nil }
        return participants(for: conversation).first?.archivedAt != nil
    }

    func activeParticipants(for conversation: BotConversation) -> [AgentRecord] {
        participants(for: conversation).filter { $0.archivedAt == nil }
    }

    /// The bots a conversation's picture and member line show: archived bots leave a group's
    /// unless every one is archived; a direct conversation always shows its bot.
    func shownParticipants(for conversation: BotConversation) -> [AgentRecord] {
        let all = participants(for: conversation)
        guard conversation.kind == .group else { return all }
        let active = all.filter { $0.archivedAt == nil }
        return active.isEmpty ? all : active
    }

    /// Why nothing can be sent here, shown in place of the composer's prompt.
    func composerUnavailableReason(for conversation: BotConversation) -> String? {
        let conversation = current(conversation)
        if conversation.kind == .group {
            if conversation.archivedAt != nil { return "This group is archived" }
            let members = participants(for: conversation)
            return !members.isEmpty && members.allSatisfy({ $0.archivedAt != nil }) ? "Every bot in this group is archived" : nil
        }
        guard let agent = participants(for: conversation).first, agent.archivedAt != nil else { return nil }
        return "\(agent.displayName) is archived"
    }

    /// A joined Hub's archived bots, by their conversations, and its archived groups.
    func archivedConversations(on mirror: HubMirror) -> [BotConversation] {
        conversations.filter { mirror.owns(conversation: $0.id) && isArchived($0) }
    }

    func unarchive(_ conversation: BotConversation) {
        if conversation.kind == .group {
            setArchived(false, conversationID: conversation.id)
        } else if let agent = participants(for: conversation).first {
            setArchived(false, agentID: agent.id)
        }
    }

    private func current(_ conversation: BotConversation) -> BotConversation {
        conversations.first { $0.id == conversation.id } ?? conversation
    }

    /// Archiving keeps the bot's workspace, memory and conversations; it only stops it running.
    @discardableResult
    func setArchived(_ archived: Bool, agentID: UUID) -> Bool {
        // A Hub's bot is archived there, for all its owner's devices; the copy here follows.
        if let mirror = hubMirror(forAgent: agentID) {
            Task {
                do { try await mirror.setArchived(archived, localAgentID: agentID) }
                catch { errorMessage = error.localizedDescription }
            }
            return true
        }
        do {
            let updated = try repository.setAgentArchived(archived, agentID: agentID)
            if let index = agents.firstIndex(where: { $0.id == agentID }) { agents[index] = updated }
            runtime.archivedAgentIDs = Set(agents.filter { $0.archivedAt != nil }.map(\.id))
            // Out of the sidebar, an unread chat could never be read.
            if archived, let direct = conversations.first(where: { $0.kind == .direct && $0.participantIDs == [agentID] }) {
                markConversationRead(direct.id)
                if selectedConversationID == direct.id { selectedConversationID = nil }
            }
            refreshAppShortcuts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setArchived(_ archived: Bool, conversationID: UUID) -> Bool {
        if let mirror = hubMirror(forConversation: conversationID) {
            Task {
                do { try await mirror.setArchived(archived, conversation: conversationID) }
                catch { errorMessage = error.localizedDescription }
            }
            return true
        }
        do {
            let before = conversations.first { $0.id == conversationID }
            let updated = try repository.setConversationArchived(archived, conversationID: conversationID)
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) { conversations[index] = updated }
            restartBots(BotConversation.botsWithChangedFolders(from: before, to: updated))
            if archived {
                markConversationRead(conversationID)
                if selectedConversationID == conversationID { selectedConversationID = nil }
            }
            refreshAppShortcuts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Keeps one mirror per joined Hub, keeps their bots out of this Mac's runtime, and
    /// follows each Hub while Noodle monitors its bots.
    func refreshHubMirrors() {
        let pairings = hubs.hubs
        let kept = pairings.map { pairing in
            hubMirrors.first { $0.pairing === pairing } ?? {
                let mirror = HubMirror(pairing: pairing, repository: repository, directory: pairing.directory)
                mirror.onChange = { [weak self] in self?.hubBotsChanged() }
                mirror.onRead = { [weak self] in self?.readElsewhere($0, upTo: $1) }
                mirror.onBackgroundChanged = { [weak self] in self?.reloadBackground(of: $0) }
                // People on the Hub talk to this Mac's own bots there, which run here.
                mirror.hosting.onMessages = { [weak self] ids in
                    guard let self else { return }
                    self.runtime.notify(self.agents.filter { ids.contains($0.id) }, repository: self.repository)
                }
                mirror.hosting.phase = { [weak self] in self?.runtime.snapshot(for: $0).phase }
                mirror.onSignInPage = { [weak self] connection, url in
                    guard let self else { throw ToolProviderError("Noodle is closing.") }
                    return try await self.mcp.authorizeInBrowser(url, callbackURL: MCPController.redirectURI(for: connection.draft.endpoint))
                }
                return mirror
            }()
        }
        for (id, task) in hubMirrorTasks where !kept.contains(where: { ObjectIdentifier($0) == id }) {
            task.cancel()
            hubMirrorTasks[id] = nil
        }
        hubMirrors = kept
        runtime.remoteAgentIDs = kept.reduce(into: Set<UUID>()) { $0.formUnion($1.localAgentIDs) }
        guard transcriptRefreshTask != nil else { return }
        for mirror in kept where hubMirrorTasks[ObjectIdentifier(mirror)] == nil {
            hubMirrorTasks[ObjectIdentifier(mirror)] = Task { await mirror.run() }
        }
    }

    /// The Hub a harness choice in the bot editor runs on; nil for a harness on this Mac.
    func hubMirror(forHarness identifier: String) -> HubMirror? {
        guard let choice = HubHarnessChoice(identifier: identifier) else { return nil }
        return hubMirrors.first { $0.pairing.hub?.key == choice.hub }
    }

    func hubMirror(forConversation id: UUID) -> HubMirror? {
        hubMirrors.first { $0.owns(conversation: id) }
    }

    func hubMirror(forAgent id: UUID) -> HubMirror? {
        hubMirrors.first { $0.localAgentIDs.contains(id) }
    }

    /// Whether someone shared this bot with this Mac's user on a Noodle Hub, who then only talks with it.
    func isShared(_ agentID: UUID) -> Bool { hubMirror(forAgent: agentID)?.owner(ofAgent: agentID) != nil }

    /// The people a conversation's bots are shared with on Noodle Hubs, whom the @ menu offers by name.
    func sharedPeople(in conversation: BotConversation) -> [String] {
        conversation.participantIDs.flatMap { id in
            (hubMirror(forAgent: id).map { $0.owner(ofAgent: id) == nil ? $0.sharedNames(agent: id) : [] } ?? [])
                + hubMirrors.flatMap { $0.hosting.sharedNames(agent: id) }
        }
    }

    /// A bot here's sharing on each Hub it can be shared through, for its owner's phone.
    func hubSharing(ofAgent id: AgentRecord.ID) async -> [LinkHubSharing] {
        await sharingHubs(forLocalAgent: id).sharing(of: id)
    }

    /// Shares a bot here with exactly `people` on one of the Hubs it can be shared through, by its ID for this Mac's devices.
    func share(agentID id: AgentRecord.ID, onHub hubID: String, with people: [UUID]) async throws {
        guard let agent = agents.first(where: { $0.id == id }) else { throw LinkError("There is no such bot.") }
        try await sharingHubs(forLocalAgent: id).share(agent, onHub: hubID, with: people)
    }

    /// The joined Hubs a bot on this Mac can be shared through: each it is shared on, and each whose people may share bots.
    func sharingHubs(forLocalAgent id: AgentRecord.ID) -> [HubMirror] {
        guard runsHere(id) else { return [] }
        return hubMirrors.filter { $0.hosting.hostedAgentIDs.contains(id) || $0.pairing.status?.canShareBots == true }
    }

    /// Whether the bot runs on this Mac, so its activity and workspace are here to show.
    func runsHere(_ agentID: UUID) -> Bool { !runtime.remoteAgentIDs.contains(agentID) }

    /// The bots Settings > Bots lists: those someone shared on a Hub have nothing to set.
    var configurableAgents: [AgentRecord] { agents.filter { !isShared($0.id) } }

    func joinHub(_ invitation: String) async {
        await hubs.join(invitation)
        refreshHubMirrors()
    }

    /// Forgets the Hub here. Bots kept on it stay there for this user's other devices.
    func leaveHub(_ pairing: HubPairing) {
        hubMirrors.first { $0.pairing === pairing }?.forgetLocalCopies()
        hubs.leave(pairing)
        refreshHubMirrors()
        reload()
    }

    /// A bot set its status through Messenger.
    private func reloadStatus(of id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }),
              let saved = try? repository.loadAgents().first(where: { $0.id == id }) else { return }
        agents[index].status = saved.status
    }

    private func hubBotsChanged() {
        runtime.remoteAgentIDs = hubMirrors.reduce(into: Set<UUID>()) { $0.formUnion($1.localAgentIDs) }
        if let selectedConversationID, !((try? repository.loadConversations()) ?? []).contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = nil
        }
        reload()
    }

    /// `tools` stores, on this Mac, what the new bot may use here.
    /// `connectionIDs`, `computerIDs` and `browserIDs` are the person's on that Hub, not this Mac's.
    private func createHubAgent(on choice: HubHarnessChoice, draft: LinkBotDraft, connectionIDs: Set<UUID>,
                                computerIDs: Set<UUID>, browserIDs: Set<UUID>) -> Bool {
        guard let mirror = hubMirrors.first(where: { $0.pairing.hub?.key == choice.hub }) else {
            errorMessage = "Join that Noodle Hub again before creating a bot on it."
            return false
        }
        creationSheet = nil
        Task {
            do {
                let agent = try await mirror.createBot(draft)
                if !connectionIDs.isEmpty { try await mirror.assignConnections(connectionIDs, toAgent: agent.id) }
                if !computerIDs.isEmpty { try await mirror.assignComputers(computerIDs, toAgent: agent.id) }
                if !browserIDs.isEmpty { try await mirror.assignBrowsers(browserIDs, toAgent: agent.id) }
                selectedConversationID = conversations.first { $0.kind == .direct && $0.participantIDs == [agent.id] }?.id
                joinShownSpace(selectedConversationID)
                refreshAppShortcuts()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    /// Sends what was just written in a conversation with a bot on a Hub.
    private func sendToHub(_ conversationID: UUID) {
        guard let mirror = hubMirrors.first(where: { $0.owns(conversation: conversationID) }) else { return }
        Task { await mirror.pushPending() }
    }

    /// Takes a Noodle Hub invitation link to Settings > Companions. Returns false for any other link.
    func receiveHubInvitation(_ url: URL) -> Bool {
        guard url.host == LinkInvitation.urlHost else { return false }
        pendingHubInvitation = url.absoluteString
        selectedSettingsTab = .hub
        return true
    }

    func createAgent(
        named name: String,
        harnessIdentifier: String,
        modelIdentifier: String?,
        reasoningEffort: String?,
        avatarSymbolName: String?,
        avatarColorIndex: Int,
        avatarImageData: Data?,
        publicDescription: String,
        backstory: String,
        mcpConnectionIDs: Set<UUID> = [],
        computerIDs: Set<UUID> = [],
        browserIDs: Set<UUID> = [],
        calendarIDs: Set<String> = [],
        reminderListIDs: Set<String> = [],
        folders: [AgentFolder] = [],
        harnessProfile: UUID? = nil,
        voice: String? = nil
    ) -> Bool {
        if let choice = HubHarnessChoice(identifier: harnessIdentifier) {
            var draft = LinkBotDraft(
                name: name, provider: choice.provider, profile: choice.profile,
                model: modelIdentifier.flatMap { $0.isEmpty ? nil : $0 },
                reasoningEffort: reasoningEffort.flatMap { $0.isEmpty ? nil : $0 }, publicDescription: publicDescription,
                backstory: backstory, avatarSymbolName: avatarSymbolName, avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData)
            draft.voice = validVoice(voice, harnessIdentifier: choice.provider)
            return createHubAgent(on: choice, draft: draft, connectionIDs: mcpConnectionIDs, computerIDs: computerIDs, browserIDs: browserIDs)
        }
        guard runtime.availableInstallations.contains(where: { $0.provider.rawValue == harnessIdentifier }) else {
            errorMessage = "Set up a supported harness in Settings before creating a bot."
            return false
        }
        var created: CreatedAgentWorkspace?
        var checkpoint: AgentSettingsCheckpoint?
        do {
            try mcp.validateAssignment(mcpConnectionIDs)
            try computers.validate(computerIDs)
            try browsers.validate(browserIDs)
            try calendars.validate(calendarIDs)
            try reminders.validate(reminderListIDs)
            checkpoint = try AgentSettingsCheckpoint(repository: repository)
            let result = try repository.createAgent(
                named: name, harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier, reasoningEffort: reasoningEffort,
                publicDescription: publicDescription, avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex, avatarImageData: avatarImageData, backstory: backstory
            )
            created = result
            if !folders.isEmpty { try repository.updateAgentFolders(result.agent, folders: folders) }
            if let profile = validHarnessProfile(harnessProfile, harnessIdentifier: harnessIdentifier) {
                try repository.updateAgentHarnessProfile(result.agent, profile: profile)
            }
            if let voice = validVoice(voice, harnessIdentifier: harnessIdentifier) {
                try repository.updateAgentVoice(result.agent, voice: voice)
            }
            try mcp.assign(mcpConnectionIDs, to: result.agent, synchronizeWorkspace: false)
            try computers.assign(computerIDs, to: result.agent, synchronizeWorkspace: false)
            try browsers.assign(browserIDs, to: result.agent, synchronizeWorkspace: false)
            try calendars.assign(calendarIDs, to: result.agent, synchronizeWorkspace: false)
            try reminders.assign(reminderListIDs, to: result.agent, synchronizeWorkspace: false)
            try repository.synchronizeAgentWorkspace(result.agent)
        } catch {
            var detail = error.localizedDescription
            do {
                try checkpoint?.restore()
                try mcp.reloadAssignments(); try computers.reloadAssignments(); try browsers.reloadAssignments(); try calendars.reloadAssignments(); try reminders.reloadAssignments()
                if let created {
                    try repository.deleteConversation(id: created.conversation.id)
                    try FileManager.default.removeItem(at: repository.storage(for: created.agent.id).package)
                }
            } catch { detail += " Previous settings could not be fully restored: \(error.localizedDescription)" }
            errorMessage = detail
            return false
        }
        guard let created else { return false }
        // Publish app state and access only after all settings have been saved.
        agents.append(created.agent)
        runtime.authorizeSelectedHarness(created.agent)
        conversations.insert(created.conversation, at: 0)
        messagesByConversation[created.conversation.id] = []
        attachmentsByConversation[created.conversation.id] = []
        startAgentServicesAfterSave()
        runtime.refresh(agents: agents)
        runtime.start(agent: created.agent, repository: repository)
        selectedConversationID = created.conversation.id
        joinShownSpace(created.conversation.id)
        creationSheet = nil
        refreshAppShortcuts()
        return true
    }

    func updateAgent(
        _ agent: AgentRecord,
        name: String,
        harnessIdentifier: String,
        modelIdentifier: String?,
        reasoningEffort: String?,
        avatarSymbolName: String?,
        avatarColorIndex: Int,
        avatarImageData: Data?,
        publicDescription: String,
        backstory: String,
        mcpConnectionIDs: Set<UUID>? = nil,
        computerIDs: Set<UUID>? = nil,
        browserIDs: Set<UUID>? = nil,
        calendarIDs: Set<String>? = nil,
        reminderListIDs: Set<String>? = nil,
        folders: [AgentFolder]? = nil,
        harnessProfile: UUID?? = nil,
        sharedWith: Set<UUID>? = nil,
        sharedOnHubs: [URL: Set<UUID>]? = nil,
        voice: String?? = nil
    ) -> Bool {
        if let mirror = hubMirror(forAgent: agent.id) {
            let choice = HubHarnessChoice(identifier: harnessIdentifier) ?? mirror.harness(ofAgent: agent.id)
            var draft = LinkBotDraft(name: name, provider: choice?.provider ?? harnessIdentifier, profile: choice?.profile,
                                     model: modelIdentifier.flatMap { $0.isEmpty ? nil : $0 },
                                     reasoningEffort: reasoningEffort.flatMap { $0.isEmpty ? nil : $0 },
                                     publicDescription: publicDescription, backstory: backstory, avatarSymbolName: avatarSymbolName,
                                     avatarColorIndex: avatarColorIndex, avatarImageData: avatarImageData)
            // Nil keeps the voice the Hub has.
            draft.voice = voice.flatMap { validVoice($0, harnessIdentifier: draft.provider) } ?? self.voice(for: agent)
            agentBeingEdited = nil
            Task {
                do {
                    try await mirror.updateBot(localAgentID: agent.id, with: draft)
                    // The Hub's connections, computers and browsers, chosen in their tabs.
                    if let mcpConnectionIDs, mcpConnectionIDs != mirror.connectionIDs(forAgent: agent.id) {
                        try await mirror.assignConnections(mcpConnectionIDs, toAgent: agent.id)
                    }
                    if let computerIDs, computerIDs != mirror.computerIDs(forAgent: agent.id) {
                        try await mirror.assignComputers(computerIDs, toAgent: agent.id)
                    }
                    if let browserIDs, browserIDs != mirror.browserIDs(forAgent: agent.id) {
                        try await mirror.assignBrowsers(browserIDs, toAgent: agent.id)
                    }
                    if let sharedWith, sharedWith != Set(mirror.sharedWith(agent: agent.id)) {
                        try await mirror.share(localAgentID: agent.id, with: Array(sharedWith))
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return true
        }
        var checkpoint: AgentSettingsCheckpoint?
        let updated: AgentRecord
        let previousBackstory: String
        var updatedConversations = conversations
        do {
            if let mcpConnectionIDs { try mcp.validateAssignment(mcpConnectionIDs) }
            if let computerIDs { try computers.validate(computerIDs) }
            if let browserIDs { try browsers.validate(browserIDs) }
            if let calendarIDs { try calendars.validate(calendarIDs) }
            if let reminderListIDs { try reminders.validate(reminderListIDs) }
            previousBackstory = try repository.loadAgentBackstory(agent)
            checkpoint = try AgentSettingsCheckpoint(repository: repository, agent: agent, conversations: conversations)
            updated = try repository.updateAgent(
                agent, displayName: name, harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier, reasoningEffort: reasoningEffort,
                publicDescription: publicDescription, avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex, avatarImageData: avatarImageData
            )
            for index in updatedConversations.indices where updatedConversations[index].kind == .direct &&
                updatedConversations[index].participantIDs == [agent.id] {
                updatedConversations[index].displayName = updated.displayName
                updatedConversations[index].updatedAt = updated.updatedAt
                try repository.updateConversation(updatedConversations[index])
            }
            try repository.updateAgentBackstory(updated, backstory: backstory)
            if let folders { try repository.updateAgentFolders(updated, folders: folders) }
            // Nil keeps the saved profile, unless the harness no longer matches it.
            let savedProfile = try repository.loadAgentHarnessProfile(updated)
            let profile = validHarnessProfile(harnessProfile ?? savedProfile, harnessIdentifier: harnessIdentifier)
            if profile != savedProfile { try repository.updateAgentHarnessProfile(updated, profile: profile) }
            if let voice { try repository.updateAgentVoice(updated, voice: validVoice(voice, harnessIdentifier: harnessIdentifier)) }
            if let mcpConnectionIDs { try mcp.assign(mcpConnectionIDs, to: updated, synchronizeWorkspace: false) }
            if let computerIDs { try computers.assign(computerIDs, to: updated, synchronizeWorkspace: false) }
            if let browserIDs { try browsers.assign(browserIDs, to: updated, synchronizeWorkspace: false) }
            if let calendarIDs { try calendars.assign(calendarIDs, to: updated, synchronizeWorkspace: false) }
            if let reminderListIDs { try reminders.assign(reminderListIDs, to: updated, synchronizeWorkspace: false) }
            try repository.synchronizeAgentWorkspace(updated)
        } catch {
            var detail = error.localizedDescription
            if let checkpoint {
                do {
                    try checkpoint.restore()
                    try mcp.reloadAssignments(); try computers.reloadAssignments(); try browsers.reloadAssignments(); try calendars.reloadAssignments(); try reminders.reloadAssignments()
                    // Generated skills derive from the restored settings. A damaged
                    // workspace may still need repair before it can be synchronized.
                    try repository.synchronizeAgentWorkspace(agent)
                } catch { detail += " Previous settings were restored where possible; workspace repair is still needed: \(error.localizedDescription)" }
            }
            errorMessage = detail
            return false
        }
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = updated }
        conversations = updatedConversations
        runtime.authorizeSelectedHarness(updated)
        startAgentServicesAfterSave()
        runtime.restart(agent: updated, repository: repository,
            resetThread: previousBackstory != backstory.trimmingCharacters(in: .whitespacesAndNewlines))
        agentBeingEdited = nil
        refreshAppShortcuts()
        // People on each Hub, by the folder this Mac keeps it in, talk to it there while it runs here.
        for hub in sharingHubs(forLocalAgent: updated.id) {
            guard let people = sharedOnHubs?[hub.pairing.directory], people != Set(hub.hosting.sharedWith(agent: updated.id)) else { continue }
            Task {
                do { try await hub.hosting.share(updated, with: Array(people)) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        return true
    }

    private func startAgentServicesAfterSave() {
        errorMessage = nil
        guard connectsServices else { return }
        computers.start(agents: agents)
        browsers.start(agents: agents)
        applets.start(agents: agents)
        mcp.start(agents: agents)
        do { try messenger.start(agents: agents) }
        catch { errorMessage = "Bot settings were saved, but Messenger could not start: \(error.localizedDescription)" }
        do { try tools.start(agents: toolAgents) }
        catch { errorMessage = "Bot settings were saved, but tools could not start: \(error.localizedDescription)" }
    }

    private var toolAgents: [ToolBridgeAgent] {
        agents.map { ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0)) }
    }

    func backstory(for agent: AgentRecord) -> String {
        do {
            return try repository.loadAgentBackstory(agent)
        } catch {
            errorMessage = error.localizedDescription
            return ""
        }
    }

    func harnessProfile(for agent: AgentRecord) -> UUID? {
        validHarnessProfile(try? repository.loadAgentHarnessProfile(agent), harnessIdentifier: agent.harnessIdentifier ?? "")
    }

    private func validHarnessProfile(_ id: UUID?, harnessIdentifier: String) -> UUID? {
        guard let profile = harnessProfiles.profile(id), profile.provider.rawValue == harnessIdentifier else { return nil }
        return profile.id
    }

    /// Bots on a deleted profile return to the system profile, never to another account.
    func deleteHarnessProfile(_ profile: HarnessProfile) {
        do {
            let affected = agents.filter { (try? repository.loadAgentHarnessProfile($0)) == profile.id }
            for agent in affected { try repository.updateAgentHarnessProfile(agent, profile: nil) }
            try harnessProfiles.delete(profile)
            for agent in affected { runtime.restart(agent: agent, repository: repository) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func folders(for agent: AgentRecord) -> [AgentFolder] {
        do {
            return try repository.loadAgentFolders(agent)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// The bots a group kept on `hub` may have, or on this Mac when nil. Groups never mix the two.
    func groupCandidates(on hub: HubMirror?) -> [AgentRecord] {
        if let hub { return agents.filter { hub.localAgentIDs.contains($0.id) && hub.owner(ofAgent: $0.id) == nil } }
        return agents.filter { !runtime.remoteAgentIDs.contains($0.id) }
    }

    /// A group's folders reach its bots' sandbox only when they launch.
    private func restartBots(_ ids: Set<UUID>) {
        for agent in agents where ids.contains(agent.id) { runtime.restart(agent: agent, repository: repository) }
    }

    func createGroup(named name: String, publicDescription: String, participantIDs: Set<UUID>, folders: [AgentFolder] = [],
                     on hub: HubMirror? = nil) -> Bool {
        if let hub {
            creationSheet = nil
            Task {
                do {
                    let conversation = try await hub.createGroup(named: name, publicDescription: publicDescription,
                                                                 agentIDs: Array(participantIDs))
                    selectedConversationID = conversation.id
                    joinShownSpace(conversation.id)
                    refreshAppShortcuts()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return true
        }
        do {
            let conversation = try repository.createGroup(
                named: name,
                publicDescription: publicDescription,
                participantIDs: Array(participantIDs),
                existingAgents: agents,
                folders: folders
            )
            conversations.insert(conversation, at: 0)
            restartBots(BotConversation.botsWithChangedFolders(from: nil, to: conversation))
            messagesByConversation[conversation.id] = []
            attachmentsByConversation[conversation.id] = []
            selectedConversationID = conversation.id
            joinShownSpace(conversation.id)
            creationSheet = nil
            refreshAppShortcuts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateGroup(
        _ conversation: BotConversation,
        named name: String,
        publicDescription: String,
        participantIDs: Set<UUID>,
        folders: [AgentFolder]? = nil
    ) -> Bool {
        if let hub = hubMirror(forConversation: conversation.id) {
            groupBeingEdited = nil
            Task {
                do {
                    try await hub.updateGroup(conversation.id, named: name, publicDescription: publicDescription,
                                              agentIDs: Array(participantIDs))
                    refreshAppShortcuts()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return true
        }
        do {
            let membershipChanged = participantIDs != Set(conversation.participantIDs)
            let normalizedDescription = publicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let descriptionChanged = (conversation.publicDescription ?? "") != normalizedDescription
            let updated = try repository.updateGroup(
                conversationID: conversation.id,
                named: name,
                publicDescription: publicDescription,
                participantIDs: Array(participantIDs),
                existingAgents: agents,
                folders: folders
            )
            let before = conversations.first { $0.id == conversation.id } ?? conversation
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = updated
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }
            restartBots(BotConversation.botsWithChangedFolders(from: before, to: updated))
            if membershipChanged || descriptionChanged {
                messagesByConversation[conversation.id] = try repository.loadMessages(
                    conversationID: conversation.id
                )
                runtime.notify(participants(for: updated), repository: repository)
            }
            groupBeingEdited = nil
            refreshAppShortcuts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func delete(_ conversation: BotConversation) -> Bool {
        let agent = conversation.kind == .direct
            ? participants(for: conversation).first
            : nil

        if let agent, let mirror = hubMirror(forAgent: agent.id) {
            Task {
                do {
                    try await mirror.deleteBot(localAgentID: agent.id)
                    drafts.clear(conversation.id)
                    if selectedConversationID == conversation.id { selectedConversationID = nil }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            agentBeingEdited = nil
            return true
        }

        if agent == nil, let hub = hubMirror(forConversation: conversation.id) {
            Task {
                do {
                    try await hub.deleteGroup(conversation.id)
                    drafts.clear(conversation.id)
                    if selectedConversationID == conversation.id { selectedConversationID = nil }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            groupBeingEdited = nil
            return true
        }

        if let agent {
            runtime.stop(agentID: agent.id, revokeAccess: false)
        }

        do {
            if let agent {
                try repository.deleteAgent(agent)
                runtime.stop(agentID: agent.id)
            } else {
                try repository.deleteConversation(id: conversation.id)
                restartBots(BotConversation.botsWithChangedFolders(from: conversation, to: nil))
            }

            drafts.clear(conversation.id)
            if selectedConversationID == conversation.id {
                selectedConversationID = nil
            }
            reload()
            agentBeingEdited = nil
            groupBeingEdited = nil
            return true
        } catch {
            if let agent {
                runtime.start(agent: agent, repository: repository)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deletionMessage(for conversation: BotConversation) -> String {
        let name = title(for: conversation)
        if conversation.kind == .direct {
            return "\u{201c}\(name)\u{201d}, its workspace, and its direct conversation will be permanently deleted. It will also be removed from every group. This cannot be undone."
        }
        return "\u{201c}\(name)\u{201d}, its messages, and its attachments will be permanently deleted. The bots in the group will not be deleted. This cannot be undone."
    }

    @ObservationIgnored lazy var voiceCalls = VoiceCallController(
        runtime: VoiceCallRouter(local: runtime, isOnHub: { [weak self] in self?.hubMirror(forAgent: $0) != nil },
                                 openHubCall: { [weak self] agentID, request in
            guard let mirror = self?.hubMirror(forAgent: agentID) else { throw VoiceCallUnavailable() }
            return try await mirror.openCall(in: request.conversationID, offer: request.offer)
        }),
        makeMedia: { WebRTCVoiceCallMedia() }, report: { [weak self] in self?.errorMessage = $0 },
        record: { [weak self] in self?.recordVoiceCall($0) },
        finish: { [weak self] in self?.finishVoiceCall($0, messageID: $1, endedAt: $2) })

    private func recordVoiceCall(_ call: VoiceCallController.Call) -> UUID? {
        // A Hub keeps its bots' calls and sends the card here like any message.
        guard runsHere(call.agentID) else { return nil }
        do {
            let message = try repository.recordVoiceCall(agentID: call.agentID, conversationID: call.conversationID)
            markConversationRead(call.conversationID)
            messagesByConversation[call.conversationID, default: []].append(message)
            if let index = conversations.firstIndex(where: { $0.id == call.conversationID }) {
                conversations[index].updatedAt = message.createdAt
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }
            sendToHub(call.conversationID)
            return message.id
        } catch {
            errorMessage = "Could not add the call to the conversation: \(error.localizedDescription)"
            return nil
        }
    }

    private func finishVoiceCall(_ call: VoiceCallController.Call, messageID: UUID, endedAt: Date) {
        do {
            let message = try repository.finishVoiceCall(messageID: messageID, conversationID: call.conversationID,
                                                         lines: call.lines, endedAt: endedAt)
            if let index = messagesByConversation[call.conversationID]?.firstIndex(where: { $0.id == messageID }) {
                messagesByConversation[call.conversationID]?[index] = message
            }
            sendToHub(call.conversationID)
        } catch {
            errorMessage = "Could not save the call's transcript: \(error.localizedDescription)"
        }
    }

    /// A voice from another harness is dropped rather than kept for a harness that cannot use it.
    private func validVoice(_ voice: String?, harnessIdentifier: String) -> String? {
        guard let voice, HarnessProvider(rawValue: harnessIdentifier)?.voices.contains(where: { $0.id == voice }) == true else { return nil }
        return voice
    }

    @ObservationIgnored var voiceGuesser: any VoicePresentationGuessing = AppleVoicePresentationGuesser()

    func voice(for agent: AgentRecord) -> String? { try? repository.loadAgentVoice(agent) }

    /// What a bot with this name sounds like until a voice is chosen for it.
    func defaultVoice(forBotNamed name: String, harnessIdentifier: String) async -> String? {
        // A harness a Hub lends speaks with the same voices.
        await BotVoice.fitting(name: name, harnessIdentifier: HubHarnessChoice(identifier: harnessIdentifier)?.provider ?? harnessIdentifier,
                               guesser: voiceGuesser)
    }

    /// The card of the call in progress in a conversation. A Hub's card arrives once the call
    /// connects, so until then it is the newest call there still going.
    func liveCallCardID(in conversationID: UUID) -> UUID? {
        guard let call = voiceCalls.call, call.conversationID == conversationID else { return nil }
        return call.messageID ?? messagesByConversation[conversationID]?.last { $0.call != nil && $0.call?.endedAt == nil }?.id
    }

    /// Calls are one-to-one with a bot whose harness has voices: on this Mac, or on a Hub, which
    /// says so for each bot, shared ones included. The bot need not be running: calling starts it.
    func voiceCallTarget(for conversation: BotConversation) -> AgentRecord? {
        guard conversation.kind == .direct, let agent = participants(for: conversation).first else { return nil }
        if let mirror = hubMirror(forAgent: agent.id) { return mirror.canCall(agent: agent.id) ? agent : nil }
        guard runsHere(agent.id), HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.voices.isEmpty == false else { return nil }
        return agent
    }

    func startVoiceCall(in conversation: BotConversation, media: (any VoiceCallMedia)? = nil) {
        guard let agent = voiceCallTarget(for: conversation) else { return }
        let personName = (try? repository.loadAgentOwner(agent))?.name ?? "User"
        let recentLines = messages(for: conversation).suffix(12).compactMap { message -> VoiceCallLine? in
            switch message.author {
            case .user: .init(.person, message.body)
            case .agent: .init(.bot, message.body)
            case .system: nil
            }
        }
        let onHub = !runsHere(agent.id)
        if !onHub { runtime.start(agent: agent, repository: repository) }
        Task {
            // A Hub starts its bot and picks its voice itself.
            let voice = onHub ? nil : await BotVoice.forCall(agent, repository: repository, guesser: voiceGuesser)
            voiceCalls.start(agentID: agent.id, conversationID: conversation.id, voice: voice,
                             personName: personName, recentLines: recentLines, media: media)
        }
    }

    /// There is one call at a time, so this ends it from any window; otherwise it calls the conversation's bot.
    func toggleVoiceCall(in conversationID: UUID?, media: (any VoiceCallMedia)? = nil) {
        if voiceCalls.call != nil { return voiceCalls.hangUp() }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        startVoiceCall(in: conversation, media: media)
    }

    func sendVoiceMessage(from url: URL, voice: VoiceMessage, to conversationID: UUID) throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let attachment = try repository.importAttachment(from: url, into: conversationID, mediaType: "audio/x-caf", voice: voice)
        attachmentsByConversation[conversationID, default: []].append(attachment)
        // Staged files usually relate to what was said, so they travel with the recording.
        let staged = pendingAttachments(for: conversationID)
        let message = try repository.sendUserMessage(conversationID: conversationID,
            body: VoiceMessage.messageBody, attachmentIDs: staged.map(\.id) + [attachment.id])
        drafts[conversationID].attachments = []
        markConversationRead(conversationID)
        messagesByConversation[conversationID, default: []].append(message)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].updatedAt = message.createdAt
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
        // The text draft is independent and remains untouched.
        runtime.notify(participants(for: conversation), repository: repository)
        voiceCalls.shared(in: conversationID, body: voice.transcript ?? VoiceMessage.messageBody,
                          attachmentNames: staged.map(\.originalFilename))
        sendToHub(conversationID)
    }

    func sendDraft() {
        guard let selectedConversationID else { return }
        sendDraft(to: selectedConversationID)
    }

    func sendDraft(to conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let body = draft(for: conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = pendingAttachments(for: conversationID)
        guard !body.isEmpty || !pendingAttachments.isEmpty else { return }
        let messageBody = body.isEmpty ? "Sent \(pendingAttachments.count) attachment\(pendingAttachments.count == 1 ? "" : "s")" : body

        do {
            let message = try repository.sendUserMessage(
                conversationID: conversation.id,
                body: messageBody,
                attachmentIDs: pendingAttachments.map(\.id)
            )
            markConversationRead(conversation.id)
            messagesByConversation[conversation.id, default: []].append(message)

            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].updatedAt = message.createdAt
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }

            drafts.clear(conversation.id)
            runtime.notify(participants(for: conversation), repository: repository)
            voiceCalls.shared(in: conversation.id, body: body, attachmentNames: pendingAttachments.map(\.originalFilename))
            sendToHub(conversation.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func sendCommand(_ command: String, to conversationID: UUID) throws -> ChatMessage {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let message = try repository.sendUserMessage(
            conversationID: conversation.id,
            body: command
        )
        markConversationRead(conversation.id)
        messagesByConversation[conversation.id, default: []].append(message)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].updatedAt = message.createdAt
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
        runtime.notify(participants(for: conversation), repository: repository)
        sendToHub(conversation.id)
        return message
    }

    func messages(for conversation: BotConversation) -> [ChatMessage] {
        messagesByConversation[conversation.id, default: []]
    }

    func transcriptViewport(for conversation: BotConversation) -> TranscriptViewport {
        transcriptPositions.viewport(for: conversation.id)
            .restored(availableMessageIDs: Set(messages(for: conversation).map(\.id)))
    }

    func saveTranscriptViewport(_ viewport: TranscriptViewport, for conversationID: UUID) {
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        do { try transcriptPositions.save(viewport, for: conversationID) }
        catch { errorMessage = "Could not save the conversation’s reading position: \(error.localizedDescription)" }
    }

    func hasUnreadMessages(in conversation: BotConversation) -> Bool {
        unreadConversationIDs.contains(conversation.id)
    }

    func updateDockBadge() {
        NSApplication.shared.dockTile.badgeLabel = unreadConversationIDs.isEmpty
            ? nil
            : String(unreadConversationIDs.count)
    }

    func markConversationRead(_ conversationID: UUID?) {
        guard let conversationID,
              unreadConversationIDs.contains(conversationID) else { return }
        unreadConversationIDs.remove(conversationID)
        persistUnreadConversationIDs()
        shareRead(conversationID)
    }

    /// Tells the person's other devices, through the Hub that shows them the conversation.
    /// A background chosen here: a conversation on a Hub keeps it there, and this Mac's own devices hear of it at once.
    private func shareBackground(_ conversationID: UUID) {
        if let mirror = hubMirror(forConversation: conversationID) {
            Task { await mirror.shareBackground(conversation: conversationID) }
        } else {
            thisMac.hub?.bots.checkForChanges()
        }
    }

    private func reloadBackground(of conversationID: UUID) {
        backgrounds[conversationID] = (try? repository.loadBackground(conversationID: conversationID)) ?? ConversationBackground()
    }

    private func shareRead(_ conversationID: UUID) {
        if let mirror = hubMirror(forConversation: conversationID) {
            Task { await mirror.markRead(conversation: conversationID) }
        } else {
            thisMac.hub?.markRead(conversation: conversationID)
        }
    }

    private func reloadToolsEditedElsewhere() {
        do { try mcp.reloadAssignments(); try computers.reloadAssignments(); try browsers.reloadAssignments() }
        catch { errorMessage = error.localizedDescription }
        Task {
            await mcp.readSignIns()
            await computers.refresh()
            await browsers.refresh()
        }
    }

    /// Read on another device: the dot goes, unless a bot wrote here since.
    private func readElsewhere(_ conversationID: UUID, upTo: Date) {
        guard unreadConversationIDs.contains(conversationID),
              let messages = try? repository.loadMessages(conversationID: conversationID),
              !messages.contains(where: { if case .agent = $0.author { $0.createdAt > upTo } else { false } }) else { return }
        unreadConversationIDs.remove(conversationID)
        persistUnreadConversationIDs()
    }

    func markSelectedConversationReadIfVisible() {
        guard let selectedConversationID, conversationWindows.isViewing(selectedConversationID) else { return }
        markConversationRead(selectedConversationID)
    }

    func attachments(for message: ChatMessage) -> [ConversationAttachment] {
        let byID = attachmentLookupByConversation[message.conversationID, default: [:]]
        return message.attachments.compactMap { byID[$0] }
    }

    func importAttachment(from url: URL) {
        guard let conversationID = selectedConversation?.id else { return }
        importAttachment(from: url, into: conversationID)
    }

    func importAttachment(from url: URL, into conversationID: UUID) {
        do {
            try importAttachmentFile(from: url, into: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importAttachments(from providers: [NSItemProvider]) {
        guard let conversationID = selectedConversation?.id else { return }
        importAttachments(from: providers, into: conversationID)
    }

    func importAttachments(from providers: [NSItemProvider], into conversationID: UUID,
                           context: AttachmentTransfer.Context = .drop) {
        Task {
            var firstError: Error?
            for provider in providers {
                do {
                    let payload = try await AttachmentTransfer.load(provider, context: context)
                    guard conversations.contains(where: { $0.id == conversationID }) else { return }
                    switch payload {
                    case .file(let url):
                        try importAttachmentFile(from: url, into: conversationID)
                    case .data(let data, let originalFilename, let mediaType):
                        try importAttachment(
                            data: data,
                            originalFilename: originalFilename,
                            mediaType: mediaType,
                            into: conversationID
                        )
                    }
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                errorMessage = firstError.localizedDescription
            }
        }
    }

    func importAttachmentsFromPasteboard(into conversationID: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        guard conversations.contains(where: { $0.id == conversationID }) else { return false }

        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !values.isEmpty {
            var imported = false
            for value in values {
                do {
                    try importAttachmentFile(from: value, into: conversationID)
                    imported = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return imported
        }

        if let pngData = pasteboard.data(forType: .png) {
            do {
                try importAttachment(
                    data: pngData,
                    originalFilename: "Pasted Image.png",
                    mediaType: "image/png",
                    into: conversationID
                )
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            do {
                try importAttachment(
                    data: tiffData,
                    originalFilename: "Pasted Image.tiff",
                    mediaType: "image/tiff",
                    into: conversationID
                )
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        if let text = pasteboard.string(forType: .string), LongTextPolicy.requiresPreview(text) {
            do {
                try importAttachment(data: Data(text.utf8), originalFilename: "Pasted Text.txt",
                                     mediaType: "text/plain", into: conversationID)
            } catch {
                errorMessage = error.localizedDescription
            }
            // Even on failure, leave the draft and clipboard intact for retry.
            return true
        }

        return false
    }

    func importPhoto(data: Data, into conversationID: UUID) throws {
        let payload = try AttachmentTransfer.photoPayload(data)
        if case .data(let data, let filename, let mediaType) = payload {
            try importAttachment(data: data, originalFilename: filename, mediaType: mediaType, into: conversationID)
        }
    }

    func importCapture(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String,
                       into conversationID: UUID) throws {
        let saved = try CaptureAttachment.save(image: image, title: title, region: region, comment: comment,
                                               into: conversationID, repository: repository)
        if let source = saved.source { attachmentsByConversation[conversationID, default: []].append(source) }
        attachmentsByConversation[conversationID, default: []].append(saved.attachment)
        drafts[conversationID].attachments.append(saved.attachment)
    }

    private func importAttachmentFile(from url: URL, into conversationID: UUID) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let attachment = try repository.importAttachment(
            from: url,
            into: conversationID,
            mediaType: mediaType
        )
        attachmentsByConversation[conversationID, default: []].append(attachment)
        drafts[conversationID].attachments.append(attachment)
    }

    private func importAttachment(
        data: Data,
        originalFilename: String,
        mediaType: String,
        into conversationID: UUID
    ) throws {
        let attachment = try repository.importAttachment(
            data: data,
            originalFilename: originalFilename,
            into: conversationID,
            mediaType: mediaType
        )
        attachmentsByConversation[conversationID, default: []].append(attachment)
        drafts[conversationID].attachments.append(attachment)
    }

    /// Save to the originating draft even if the selected conversation changed.
    func saveAnnotation(_ annotation: AttachmentAnnotation, content: Data, source: ConversationAttachment) throws {
        guard conversations.contains(where: { $0.id == source.conversationID }) else {
            throw WorkspaceError.missingConversation(source.conversationID)
        }
        let stem = URL(fileURLWithPath: source.originalFilename).deletingPathExtension().lastPathComponent
        let attachment = try repository.importAttachment(data: content,
            originalFilename: "Annotation — \(stem.prefix(160)).\(annotation.fileExtension)", into: source.conversationID,
            mediaType: annotation.mediaType, annotation: annotation)
        attachmentsByConversation[source.conversationID, default: []].append(attachment)
        drafts[source.conversationID].attachments.append(attachment)
    }

    func saveConversationAnnotation(_ note: AttachmentAnnotation, content: Data,
                                    source: ConversationAttachment, sourceData: Data) throws {
        let saved = try ConversationAnnotationContent.save(note, content: content, source: source,
            sourceData: sourceData, repository: repository)
        let id = source.conversationID
        attachmentsByConversation[id, default: []].append(contentsOf: [saved.source, saved.attachment])
        drafts[id].attachments.append(saved.attachment)
    }

    func canEditAnnotation(_ attachment: ConversationAttachment) -> Bool {
        drafts.canEditAnnotation(attachment, messages: messagesByConversation[attachment.conversationID, default: []])
    }

    func reviseAnnotationComment(_ attachment: ConversationAttachment, comment: String) throws -> ConversationAttachment {
        guard canEditAnnotation(attachment), let annotation = attachment.annotation else { throw WorkspaceError.invalidAttachment }
        let updated = try repository.reviseAnnotationComment(attachment, comment: comment,
            content: AnnotationContent.editedData(for: annotation.replacingComment(comment), originalURL: attachmentFileURL(attachment)))
        let conversationID = updated.conversationID
        if let index = attachmentsByConversation[conversationID, default: []].firstIndex(where: { $0.id == updated.id }) {
            attachmentsByConversation[conversationID]![index] = updated
        } else { attachmentsByConversation[conversationID, default: []].append(updated) }
        if let index = drafts[conversationID].attachments.firstIndex(where: { $0.id == updated.id }) {
            drafts[conversationID].attachments[index] = updated
        }
        return updated
    }

    func removePendingAttachment(_ attachment: ConversationAttachment) {
        do {
            try repository.removeAttachment(attachment)
            drafts[attachment.conversationID].attachments.removeAll { $0.id == attachment.id }
            attachmentsByConversation[attachment.conversationID, default: []].removeAll {
                $0.id == attachment.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealAttachment(_ attachment: ConversationAttachment) {
        NSWorkspace.shared.activateFileViewerSelecting([attachmentFileURL(attachment)])
    }

    func copyAttachment(_ attachment: ConversationAttachment) {
        let url = attachmentFileURL(attachment)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if attachment.mediaType.hasPrefix("image/"),
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(pngData, forType: .png)
            item.setData(tiffData, forType: .tiff)
            if pasteboard.writeObjects([item]) { return }
            pasteboard.clearContents()
        }

        if pasteboard.writeObjects([url as NSURL]) {
            return
        }

        errorMessage = "The attachment could not be copied."
    }

    func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        repository.attachmentFileURL(attachment)
    }

    func refreshTranscripts() {
        do {
            applyTranscriptSnapshot(try Self.loadTranscriptSnapshot(
                from: repository,
                currentConversations: conversations,
                currentMessages: messagesByConversation,
                currentAttachments: attachmentsByConversation,
                currentRevisions: transcriptRevisions
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshTranscriptsInBackground() async {
        let generation = transcriptGeneration
        let repository = repository
        let currentConversations = conversations
        let currentMessages = messagesByConversation
        let currentAttachments = attachmentsByConversation
        let currentRevisions = transcriptRevisions
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try Self.loadTranscriptSnapshot(
                    from: repository,
                    currentConversations: currentConversations,
                    currentMessages: currentMessages,
                    currentAttachments: currentAttachments,
                    currentRevisions: currentRevisions
                )
            }.value
            guard !Task.isCancelled, generation == transcriptGeneration else { return }
            applyTranscriptSnapshot(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func loadTranscriptSnapshot(
        from repository: WorkspaceRepository,
        currentConversations: [BotConversation],
        currentMessages: [UUID: [ChatMessage]],
        currentAttachments: [UUID: [ConversationAttachment]],
        currentRevisions: [UUID: TranscriptRevision]
    ) throws -> TranscriptSnapshot {
        let conversations = try repository.loadConversations().filter(\.isShownHere)
        var messages: [UUID: [ChatMessage]] = [:]
        var attachments: [UUID: [ConversationAttachment]] = [:]
        var revisions: [UUID: TranscriptRevision] = [:]
        let conversationIDs = Set(conversations.map(\.id))
        var messagesChanged = Set(currentMessages.keys) != conversationIDs
        var attachmentsChanged = Set(currentAttachments.keys) != conversationIDs
        for conversation in conversations {
            let revision = transcriptRevision(for: conversation.id, repository: repository)
            revisions[conversation.id] = revision
            if revision.messagesModifiedAt == currentRevisions[conversation.id]?.messagesModifiedAt,
               revision.messagesSize == currentRevisions[conversation.id]?.messagesSize,
               let current = currentMessages[conversation.id] {
                messages[conversation.id] = current
            } else {
                messages[conversation.id] = try repository.loadMessages(conversationID: conversation.id)
                messagesChanged = true
            }
            if revision.attachmentsModifiedAt == currentRevisions[conversation.id]?.attachmentsModifiedAt,
               let current = currentAttachments[conversation.id] {
                attachments[conversation.id] = current
            } else {
                attachments[conversation.id] = try repository.loadAttachments(conversationID: conversation.id)
                attachmentsChanged = true
            }
        }
        return TranscriptSnapshot(
            conversations: conversations,
            messages: messages,
            attachments: attachments,
            conversationsChanged: conversations != currentConversations,
            messagesChanged: messagesChanged,
            attachmentsChanged: attachmentsChanged,
            revisions: revisions
        )
    }

    nonisolated private static func transcriptRevision(
        for conversationID: UUID,
        repository: WorkspaceRepository
    ) -> TranscriptRevision {
        let fileManager = FileManager.default
        let messagesURL = repository.conversationDirectory(id: conversationID)
            .appendingPathComponent("messages.json")
        let messageAttributes = try? fileManager.attributesOfItem(atPath: messagesURL.path)
        let attachmentAttributes = try? fileManager.attributesOfItem(
            atPath: repository.attachmentsDirectory(conversationID: conversationID).path
        )
        return TranscriptRevision(
            messagesModifiedAt: messageAttributes?[.modificationDate] as? Date,
            messagesSize: (messageAttributes?[.size] as? NSNumber)?.uint64Value,
            attachmentsModifiedAt: attachmentAttributes?[.modificationDate] as? Date
        )
    }

    private func applyTranscriptSnapshot(_ snapshot: TranscriptSnapshot) {
        transcriptRevisions = snapshot.revisions
        guard snapshot.conversationsChanged || snapshot.messagesChanged || snapshot.attachmentsChanged else { return }

        let newAgentMessages: [ChatMessage]
        let reactionChanges: [MessageReactionChange]
        if snapshot.messagesChanged {
            let knownMessageIDs = Set(messagesByConversation.values.flatMap { $0.map(\.id) })
            let knownReactionIDs = Set(messagesByConversation.values.flatMap { $0 }
                .flatMap { $0.reactionChanges ?? [] }.map(\.id))
            newAgentMessages = snapshot.messages.values
                .flatMap { $0 }
                .filter { message in
                    guard !knownMessageIDs.contains(message.id) else { return false }
                    if case .agent = message.author { return true }
                    return false
                }
                .sorted { $0.createdAt < $1.createdAt }
            reactionChanges = snapshot.messages.values.flatMap { $0 }
                .flatMap { $0.reactionChanges ?? [] }.filter { !knownReactionIDs.contains($0.id) }
        } else {
            newAgentMessages = []
            reactionChanges = []
        }

        if snapshot.conversationsChanged {
            conversations = snapshot.conversations
            conversationWindows.retainConversations(Set(conversations.map(\.id)))
        }
        if snapshot.messagesChanged { messagesByConversation = snapshot.messages }
        if snapshot.attachmentsChanged { attachmentsByConversation = snapshot.attachments }
        for message in newAgentMessages {
            if case .agent(let id) = message.author { runtime.recordActivity(for: id) }
        }
        notifyGroupParticipants(for: newAgentMessages)
        for change in reactionChanges {
            if case .agent(let id) = change.author { runtime.recordActivity(for: id) }
        }
        let reactionRecipientIDs = Set(reactionChanges.flatMap { change in
            (snapshot.conversations.first { $0.id == change.conversationID }?.participantIDs ?? [])
                .filter { change.author != .agent($0) }
        })
        if !reactionRecipientIDs.isEmpty {
            runtime.notify(agents.filter { reactionRecipientIDs.contains($0.id) }, repository: repository)
        }
        registerUnreadMessages(newAgentMessages)
        postNotifications(for: newAgentMessages)
    }

    func participants(for conversation: BotConversation) -> [AgentRecord] {
        conversation.participantIDs.compactMap { id in
            agents.first(where: { $0.id == id })
        }
    }

    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        do {
            let latest = try repository.loadMessages(conversationID: message.conversationID)
                .first { $0.id == message.id }
            let hasReaction = latest?.reactions?.contains { $0.author == .user && $0.emoji == emoji } ?? false
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: !hasReaction)
            refreshTranscripts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeReaction(_ emoji: String, on message: ChatMessage) {
        do {
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: false)
            refreshTranscripts()
        } catch { errorMessage = error.localizedDescription }
    }

    func background(for conversation: BotConversation?) -> ConversationBackground {
        guard let id = conversation?.id else { return ConversationBackground() }
        return backgrounds[id] ?? ConversationBackground()
    }

    /// Save the background and enclosing settings together. A failed settings
    /// save restores the previous wallpaper without deleting its media.
    func saveSettings(background draft: BackgroundSelection?, for conversation: BotConversation?,
                      saving settings: () -> Bool) -> Bool {
        guard let draft, let conversation else { return settings() }
        struct SettingsSaveFailed: Error {}
        func commit() throws { if !settings() { throw SettingsSaveFailed() } }
        do {
            let saved: ConversationBackground
            if let file = draft.file {
                saved = try repository.setBackground(conversationID: conversation.id, file: file, commit: commit)
            } else {
                saved = try repository.setBackground(conversationID: conversation.id, preset: draft.background.preset, commit: commit)
            }
            backgrounds[conversation.id] = saved
            shareBackground(conversation.id)
            return true
        } catch is SettingsSaveFailed {
            return false // The settings operation already supplied its error.
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setBackground(_ background: ConversationBackground, imageData: Data?, file: PreparedBackgroundFile? = nil, for conversation: BotConversation) async throws {
        let repository = repository
        let saved = try await Task.detached {
            if let file { return try repository.setBackground(conversationID: conversation.id, file: file) }
            if let imageData { return try repository.setBackground(conversationID: conversation.id, imageData: imageData) }
            return try repository.setBackground(conversationID: conversation.id, preset: background.preset)
        }.value
        backgrounds[conversation.id] = saved
        shareBackground(conversation.id)
    }

    func useAttachmentAsBackground(_ attachment: ConversationAttachment) async {
        let repository = repository
        do {
            let saved = try await Task.detached {
                try repository.setBackground(from: attachment)
            }.value
            // Keep the action bound to its source chat even if selection changes during decoding.
            backgrounds[attachment.conversationID] = saved
            shareBackground(attachment.conversationID)
        } catch { errorMessage = error.localizedDescription }
    }

    func useAttachmentAsIcon(_ attachment: ConversationAttachment) async {
        let repository = repository
        do {
            let updated = try await Task.detached {
                try repository.setAgentIcon(from: attachment)
            }.value
            if let index = agents.firstIndex(where: { $0.id == updated.id }) { agents[index] = updated }
            refreshAppShortcuts()
        } catch { errorMessage = error.localizedDescription }
    }

    func changeReaction(_ emoji: String, to replacement: String, on message: ChatMessage) {
        guard emoji != replacement else { return }
        do {
            // Add first so a failed write cannot silently lose the existing reaction.
            // Idempotent writes preserve an already-present replacement and other people's badges.
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: replacement, present: true)
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: false)
            refreshTranscripts()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshAppShortcuts() {
        guard connectsServices else { return }
        NoodleShortcuts.updateAppShortcutParameters()
        publishShareDestinations()
    }

    func publishShareDestinations() {
        guard let inbox = try? SharedInbox.configured() else { return }
        try? inbox.saveDestinations(conversations.filter { composerUnavailableReason(for: $0) == nil }.map {
            ShareDestination(id: $0.id, name: title(for: $0), isGroup: $0.kind == .group)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func processSharedInbox() async {
        guard !isProcessingShares, let inbox = try? SharedInbox.configured() else { return }
        isProcessingShares = true
        defer { isProcessingShares = false }
        let repository = repository
        do {
            let pending = try await Task.detached { try inbox.pending() }.value
            for request in pending where !failedShareIDs.contains(request.id) {
                do {
                    let message = try await Task.detached {
                        try repository.sendSharedMessage(request, files: inbox.files(for: request))
                    }.value
                    refreshTranscripts()
                    if let conversation = conversations.first(where: { $0.id == message.conversationID }) {
                        runtime.notify(participants(for: conversation), repository: repository)
                    }
                    try await Task.detached { try inbox.acknowledge(request.id) }.value
                } catch {
                    failedShareIDs.insert(request.id)
                    errorMessage = "Could not deliver a shared item: \(error.localizedDescription) The item is retained for retry when Noodle restarts."
                }
            }
        } catch { errorMessage = "Could not read shared items: \(error.localizedDescription)" }
    }

    private func notifyGroupParticipants(for messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        do {
            let recipientIDs = try repository.notificationRecipientIDs(for: messages)
            let recipients = agents.filter { recipientIDs.contains($0.id) }
            if !recipients.isEmpty {
                runtime.notify(recipients, repository: repository)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerUnreadMessages(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        var updated = unreadConversationIDs
        var viewed: Set<UUID> = []
        for message in messages {
            if conversationWindows.isViewing(message.conversationID) {
                updated.remove(message.conversationID)
                viewed.insert(message.conversationID)
            } else {
                updated.insert(message.conversationID)
            }
        }
        // Read as it arrived, so the person's other devices show it read too.
        viewed.forEach(shareRead)

        guard updated != unreadConversationIDs else { return }
        unreadConversationIDs = updated
        persistUnreadConversationIDs()
    }

    private func persistUnreadConversationIDs() {
        do {
            try repository.saveUnreadConversationIDs(unreadConversationIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func postNotifications(for messages: [ChatMessage]) {
        guard connectsServices else { return }
        let presentsNotifications = NoodleNotifications.shouldPresentActivity
        if MessageReceivedSound.playsInApp(newMessages: messages.count,
                                           presentsNotifications: presentsNotifications) {
            MessageReceivedSound.play()
        }
        guard presentsNotifications else { return }

        for message in messages {
            guard case .agent(let agentID) = message.author,
                  let agent = agents.first(where: { $0.id == agentID }),
                  let conversation = conversations.first(where: { $0.id == message.conversationID }) else {
                continue
            }
            NoodleNotifications.post(
                message: message,
                from: agent,
                in: conversation
            )
        }
    }

    func title(for conversation: BotConversation) -> String {
        if conversation.kind == .direct,
           let agent = participants(for: conversation).first {
            return ConversationName.display(agent.displayName)
        }
        return ConversationName.display(conversation.displayName)
    }

    func preview(for conversation: BotConversation) -> String {
        guard let body = messages(for: conversation).last?.body else { return "No messages yet" }
        return MarkdownPlainText.convert(MessageSegment.previewText(body))
    }

    func revealWorkspace(for agent: AgentRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.directory(for: agent)])
    }

    func startAgents() {
        guard storageReady else { return }
        for agent in agents {
            let conversationIDs = Set(conversations.filter {
                $0.participantIDs.contains(agent.id)
            }.map(\.id))
            let latestMessageDate = messagesByConversation
                .filter { conversationIDs.contains($0.key) }
                .flatMap(\.value)
                .map(\.createdAt)
                .max()
            runtime.seedHeartbeatActivity(
                for: agent.id,
                at: latestMessageDate ?? agent.createdAt
            )
        }
        runtime.startAll(agents: agents, repository: repository)
        runtime.refreshCapabilities()
    }

    func startMonitoring() {
        guard transcriptRefreshTask == nil else { return }
        noodletAnnotations.listen()
        startAgents()
        transcriptRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.refreshTranscriptsInBackground()
                await self.processSharedInbox()
                guard !Task.isCancelled else { break }
                self.runtime.reconcile(agents: self.agents, repository: self.repository)
                self.runtime.checkHeartbeats()
            }
        }
        // Harnesses Noodle installed have no updater of their own. Settings need not be open.
        harnessUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                if let store = self { await store.harnessSetup.updateManagedHarnesses(store.runtime) }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
        hubCheckInTask = Task { [hubs] in await hubs.stayConnected() }
        refreshHubMirrors()
    }

    func recoverAgentsAfterWake() {
        runtime.reconcile(agents: agents, repository: repository, immediately: true)
    }

    func stopMonitoring() {
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        harnessUpdateTask?.cancel()
        harnessUpdateTask = nil
        hubCheckInTask?.cancel()
        hubCheckInTask = nil
        hubMirrorTasks.values.forEach { $0.cancel() }
        hubMirrorTasks.removeAll()
        runtime.stopAll()
    }
}

extension BotConversation {
    /// A conversation someone this Mac's bot is shared with keeps with it through a Hub is theirs; the bot reads it here.
    var isShownHere: Bool { guest == nil }
}
