#if NOODLE_DEV_HOOKS
import HubLink
import AppKit
import Darwin
import NoodleBrand
import NoodleCore
import NoodleDocument
import NoodleLaunchChecks
import NoodleScenarios
import SwiftUI
import UniformTypeIdentifiers
import NoodleRuntime
import NoodleWallpaperCore

// The scenario format, its checks and the workspace it seeds are in NoodleScenarios, shared with Noodle for Windows.
// What is here is the Mac's: the launch arguments that reshape a scenario, the preferences and settings tabs it may
// name, and the parts of a seed that live outside the workspace.

// MARK: - Load and validate

extension Scenario {
    /// `--scenario-size WIDTHxHEIGHT` opens the main window at that size instead of the scenario's own,
    /// so one scenario can be recorded in another shape without editing it.
    mutating func resize(_ checks: LaunchChecks) throws {
        guard let value = checks.value(after: DevelopmentHook.scenarioSize) else { return }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], width > 0, height > 0 else {
            throw ScenarioError("\(value) is not a window size like 1240x860.")
        }
        var present = self.present ?? .init()
        present.window = Presentation.Window(size: [width, height], origin: present.window?.origin)
        self.present = present
    }

    /// `--scenario-background`, `--scenario-without` and `--scenario-margin` change the film for one recording.
    mutating func adjustFilm(_ checks: LaunchChecks) throws {
        film = try ScenarioFilm.adjusted(film, background: checks.value(after: DevelopmentHook.scenarioBackground),
                                         without: checks.value(after: DevelopmentHook.scenarioWithout),
                                         margin: checks.value(after: DevelopmentHook.scenarioMargin), media: media)
    }

    static let settingsTabs: [String: NoodleSettingsTab] = [
        "general": .general, "chat": .chat, "harnesses": .harnesses, "bots": .bots, "groups": .groups, "mcps": .mcps,
        "keybindings": .keybindings, "permissions": .permissions, "companions": .companions, "updates": .updates
    ]

    /// Preferences a scenario may set. Message delivery is absent: the loader always queues, so the
    /// on-device classifier never runs.
    @MainActor static var preferenceKeys: Set<String> {
        [ChatAttachmentLayout.defaultsKey, BotNameStyle.defaultsKey, FirstBotSetup.dismissedKey,
         ComposerNameCompletion.descriptionsDefaultsKey, FloatingConversations.keepsOneDefaultsKey, ConversationListStyle.key,
         TaskListFilter.key]
    }

    /// Strict: a key the model does not know is an error, so a typo cannot silently change a screenshot.
    @MainActor static func load(from folder: URL) throws -> Scenario {
        try load(from: folder, preferenceKeys: preferenceKeys, settingsTabs: Set(settingsTabs.keys))
    }
}

// MARK: - Seed

extension Scenario {
    /// Replays the scenario into an empty repository and defaults domain. Harnesses become stub
    /// executables under `harnessHome`, laid out as harnesses Noodle installed: the sandbox refuses
    /// execute access inside the container, and only that kind is discovered without asking for it. Nothing runs them.
    @MainActor func seed(into repository: WorkspaceRepository, defaults: UserDefaults, harnessHome: URL, now: Date = Date()) throws -> Seeded {
        let files = FileManager.default
        let managed = ManagedHarnessStore(root: harnessHome)
        var seeded = Seeded(clock: try ScenarioTime.start(clock, now: now),
            discovery: HarnessDiscovery(homeDirectory: harnessHome, applicationsDirectory: harnessHome,
                executableSearchDirectories: [], applicationBundleURL: harnessHome, managedHarnesses: managed, environment: [:]))
        for (key, value) in settings ?? [:] { defaults.set(value.propertyListValue, forKey: key) }
        defaults.set(MessageDeliveryMode.queue.rawValue, forKey: MessageDeliveryMode.defaultsKey)

        for provider in harnesses.keys.compactMap(HarnessProvider.init(rawValue:)) {
            guard let distribution = HarnessDistribution(provider) else { continue }
            let url = managed.directory.appendingPathComponent("\(provider.rawValue)/1.0.0/\(distribution.executablePath)")
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard let executable = managed.executable(provider) else { throw ScenarioError("Could not stand in for \(provider.displayName).") }
            seeded.executables[provider] = executable
            seeded.models[provider] = models(for: provider)
        }

        try seedStore(into: repository, seeded: &seeded) { agent, data in
            guard let tint = agent.avatar?.tint, let image = NSImage(data: data) else { return data }
            return ScenarioSupport.tinted(image, tint).tiffRepresentation ?? data
        }
        var access = AgentAccessConfiguration(autonomousAgentIDs: Set(agents.filter { $0.unrestricted == true }.compactMap { seeded.agents[$0.key]?.id }))
        if !access.autonomousAgentIDs.isEmpty { defaults.set(true, forKey: AgentAccessConfiguration.unrestrictedAccessKey) }
        for agent in seeded.agents.values { access.authorizeSelectedHarness(for: agent) }
        access.save(to: defaults)
        if let columns = present?.columns {
            defaults.set(MainWindowLayout.columns.rawValue, forKey: MainWindowLayout.key)
            defaults.set(["": columns.compactMap { seeded.conversations[$0]?.id.uuidString }], forKey: ColumnsModel.key)
        }

        // The app restores conversation windows as it opens, keyed by the conversation identifiers seeded.
        let windows = (present?.windows ?? []).filter { $0.conversation != nil }
        let frames = Dictionary(uniqueKeysWithValues: windows.compactMap { window -> (UUID, String)? in
            guard let id = seeded.conversations[window.conversation ?? ""]?.id else { return nil }
            return (id, ScenarioSupport.frameDescriptor(window.frame ?? [160, 120, 760, 810]))
        })
        try JSONEncoder().encode(frames).write(to: repository.rootURL.appendingPathComponent("conversation-windows.json"))
        let floating = windows.filter { $0.floating == true }.compactMap { seeded.conversations[$0.conversation ?? ""]?.id.uuidString }
        if !floating.isEmpty { defaults.set(floating.sorted(), forKey: FloatingConversations.defaultsKey) }

        try applyOverlay(to: repository)
        return seeded
    }
}

// MARK: - Scripted bot

/// Stands where a harness process would. It reports what the scenario says and runs nothing.
@MainActor final class ScenarioAgentProcess: AgentRuntimeProcess {
    let launch: AgentRuntimeLaunch
    private weak var session: ScenarioSession?
    var configuration: AgentRecord { launch.agent }
    private(set) var snapshot: AgentRuntimeSnapshot
    private(set) var isAlive = false
    let hasInterruptedWork = false
    let canReceiveHeartbeat = false
    /// Every wake the coordinator asked for, fetched or not.
    private(set) var notifications = 0

    init(_ launch: AgentRuntimeLaunch, session: ScenarioSession?) {
        self.launch = launch
        self.session = session
        snapshot = .init(agentID: launch.agent.id, phase: .offline, detail: "Not started")
    }

    func transition(_ snapshot: AgentRuntimeSnapshot) {
        self.snapshot = snapshot
        launch.onSnapshot(snapshot)
    }

    func start() {
        isAlive = true
        if let session { transition(session.startingSnapshot(for: launch.agent)) }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        isAlive = false
        transition(.init(agentID: launch.agent.id, phase: .offline, detail: "Stopped"))
        completion(true)
    }

    /// A running harness fetches its unread messages, which is what turns Sent into Delivered.
    @discardableResult func notify(immediately: Bool) -> UUID {
        notifications += 1
        if let session, snapshot.phase == .ready || snapshot.phase == .working,
           let deliveries = try? session.repository.latestMessages(for: launch.agent.id),
           deliveries.contains(where: { $0.sender.handle == .user && $0.reactionChange == nil }) {
            session.userMessageArrived(for: launch.agent)
        }
        return UUID()
    }

    func promoteNotification(_ id: UUID) {}
    func heartbeat() {}
    func wake() {}
    func organize() {}
}

// MARK: - Session

/// One scenario in one app launch: seeds it, stands in for the harnesses, and plays the timeline.
@MainActor final class ScenarioSession {
    static let bundleIdentifier = "com.pdparchitect.noodle.scenarios"
    private(set) static var active: ScenarioSession?

    /// Where the timeline stops for someone outside the app.
    enum Pause { case key, userMessage(bot: String), shot(String) }

    let scenario: Scenario
    let seeded: Scenario.Seeded
    /// The seeded tasks and those the timeline added, by "bot key/task key".
    private lazy var taskIDs = seeded.tasks
    let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    private(set) var store: NoodleStore!
    /// Answers a pause in place of the menu and the terminal; false ends the timeline.
    var pause: (@MainActor (Pause) async -> Bool)?
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The timeline is stopped at `waitFor: key` until Next Step or a line from the terminal.
    var isWaitingForKey: Bool { terminal.isWaitingForKey }
    /// A capture run: scripts/scenario.sh photographs each `capture` step and nobody is at the keyboard.
    var takesShots = false {
        didSet {
            guard takesShots != oldValue else { return }
            // A key or click from whoever is passing the machine lands in the app and is filmed:
            // half a word in the composer, a menu open over the picture. An automated run is
            // driven from the timeline alone, so nothing else may reach it.
            if takesShots {
                inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.unwantedInput) { _ in nil }
            } else if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
        }
    }

    /// What a capture run takes away from the app: everything a person could do to it by hand.
    static let unwantedInput: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .magnify, .swipe, .rotate,
    ]
    private var inputMonitor: Any?
    /// Whether the keyboard and mouse have been taken away from the app.
    var blocksInput: Bool { inputMonitor != nil }
    /// Marks a sound for the recording's track; tests replace it to count keystrokes.
    var soundCue: (@MainActor (String) -> Void)?
    /// Plays the titles around the timeline; tests replace it to watch the order without a window.
    var playFilm: (@MainActor (Scenario.Film.Stage) async throws -> Void)?
    private var filmStage: ScenarioFilmStage?
    /// What the recording is moving in on, so typing can keep the picture with it.
    private var focusRegion: String?
    private var processes: [UUID: ScenarioAgentProcess] = [:]
    private var started: Set<UUID> = []
    private var arrivals: [UUID: Int] = [:]
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var timelineEnded = false
    private var nextAutoReply: [UUID: Int] = [:]
    private let terminal = ScenarioTerminal()
    private var liveMessages: [String: ChatMessage] = [:]
    /// What opened this scenario, a name or a path, which Reload opens again; nil while only the picker is open.
    private(set) var selection: String?
    private let launchedAt = Date()

    /// Scenarios replace the app's data, so they run only in the bundle scripts/scenario.sh derives,
    /// which has its own container and preferences and no network, account or group entitlement.
    static func isIsolated(bundleIdentifier: String?) -> Bool { bundleIdentifier == Self.bundleIdentifier }

    init(_ scenario: Scenario, root: URL, defaults: UserDefaults) throws {
        self.scenario = scenario
        repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle", isDirectory: true))
        seeded = try scenario.seed(into: repository, defaults: defaults, harnessHome: root.appendingPathComponent("Home", isDirectory: true))
        let seeded = seeded
        weak var session: ScenarioSession?
        runtime = AgentRuntimeCoordinator(discovery: seeded.discovery, defaults: defaults,
            makeProcess: { launch in
                let process = ScenarioAgentProcess(launch, session: session)
                session?.processes[launch.agent.id] = process
                return process
            },
            inspectHost: { provider in
                HarnessHostInspection(executablePath: seeded.executables[provider]?.path, models: seeded.models[provider] ?? [],
                    capabilityError: seeded.executables[provider] == nil ? "\(provider.displayName) is not installed" : nil)
            })
        session = self
        runtime.scriptedModels = seeded.models
        store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        if let message = store.errorMessage { throw ScenarioError(message) }
        // Shots of a scenario that asks for dark look the same on a Mac set to light.
        if scenario.appearance == "dark" { NSApp?.appearance = NSAppearance(named: .darkAqua) }
        apply(scenario.present ?? .init())
    }

    func process(for key: String) -> ScenarioAgentProcess? { seeded.agents[key].flatMap { processes[$0.id] } }

    /// The scenario's status the first time a bot starts; after a Kick it simply comes back ready.
    func startingSnapshot(for agent: AgentRecord) -> AgentRuntimeSnapshot {
        let first = started.insert(agent.id).inserted
        return scenario.snapshot(first ? scenario.agents.first { seeded.agents[$0.key]?.id == agent.id }?.status : nil, for: agent)
    }

    /// The scenario clock plus the time this launch has run, so live messages follow the seeded ones.
    var now: Date { seeded.clock.addingTimeInterval(Date().timeIntervalSince(launchedAt)) }

    func userMessageArrived(for agent: AgentRecord) {
        arrivals[agent.id, default: 0] += 1
        let waiters = arrivalWaiters
        arrivalWaiters = []
        waiters.forEach { $0.resume() }
        // Once the timeline has ended a bot answers from its own short script, in the conversation written to last.
        guard timelineEnded, let entry = scenario.agents.first(where: { seeded.agents[$0.key]?.id == agent.id }),
              let replies = entry.autoReplies, !replies.isEmpty,
              let conversation = try? repository.loadConversations().first(where: { $0.participantIDs.contains(agent.id) }) else { return }
        let text = replies[nextAutoReply[agent.id, default: 0] % replies.count]
        nextAutoReply[agent.id, default: 0] += 1
        Task { @MainActor in
            self.process(for: entry.key)?.transition(self.scenario.snapshot(.init(phase: .working), for: agent))
            try? await self.sleep(.seconds(1.5))
            _ = try? self.repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id, body: text, now: self.now)
            self.store.refreshTranscripts()
            self.process(for: entry.key)?.transition(self.scenario.snapshot(nil, for: agent))
        }
    }

    // MARK: Timeline

    func play() async throws {
        defer { timelineEnded = true }
        try await play(.intro)
        for step in scenario.timeline ?? [] {
            if let wait = step.wait, wait > 0 { try await sleep(.seconds(wait)) }
            guard try await perform(step) else { return }
        }
        try await play(.outro)
    }

    private func play(_ stage: Scenario.Film.Stage) async throws {
        // The titles are for the camera; someone watching gets straight to the timeline.
        guard takesShots, scenario.film != nil else { return }
        if let playFilm { try await playFilm(stage); return }
        try await filmStage?.play(stage, sleep: sleep)
    }

    /// Opens the scenario's windows, then runs the benchmark or, for a capture run, plays the timeline.
    /// Opened to look at, a scenario stays in its starting state, with nothing moving on its own.
    func start(benchmark: String?) async throws {
        await arrangeWindows(scenario.present ?? .init(), initial: true)
        await announceReady()
        if let benchmark, let window = mainWindow {
            await ScenarioBenchmark(session: self, phases: benchmark, window: window).run()
            NSApp.terminate(nil)
            return
        }
        guard takesShots else { return }
        try await play()
        await announceDone()
        NSApp.terminate(nil)
    }

    /// False when the timeline cannot go on.
    private func perform(_ step: Scenario.Step) async throws -> Bool {
        let agent = step.agent.flatMap { seeded.agents[$0] }
        let conversation = step.in.flatMap { seeded.conversations[$0] } ?? step.agent.flatMap { seeded.directs[$0] }
        if let status = step.status, let agent {
            process(for: step.agent ?? "")?.transition(scenario.snapshot(status, for: agent))
        }
        if let task = step.task, let agent {
            try scenario.apply(task, of: step.agent ?? "", seeded: seeded, taskIDs: &taskIDs, repository: repository, now: now)
            store.reloadTasks(of: agent.id)
        }
        if let reply = step.reply, let agent, let conversation {
            let date = now
            let message = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id, body: reply.text,
                attachmentIDs: try scenario.importAttachments(reply.attachments, into: conversation.id, repository: repository, now: date), now: date)
            remember(message, as: reply.key)
            store.refreshTranscripts()
            cue("reply")
        }
        if let say = step.say, let conversation {
            let date = now
            let message = try repository.sendUserMessage(conversationID: conversation.id, body: say.text,
                attachmentIDs: try scenario.importAttachments(say.attachments, into: conversation.id, repository: repository, now: date), now: date)
            remember(message, as: say.key)
            store.refreshTranscripts()
            runtime.notify(store.participants(for: conversation), repository: repository)
        }
        if let typing = step.type, let conversation {
            var typed = ""
            for character in typing.text {
                typed.append(character)
                store.setDraft(typed, for: conversation.id)
                cue("key")
                // The picture keeps up with the writing, letter by letter and at one
                // speed: eased steps would make it pulse rather than travel.
                if focusRegion == "composer" { cueFocus("composer", over: 0.15, steady: true) }
                // Keys land unevenly. Evenly spaced ones beat like a rotor once they have a sound.
                try await sleep(.seconds((typing.interval ?? 0.075) * Double.random(in: 0.55...1.65)))
            }
            // The picture pulls back as the hand reaches for Return, so the message
            // lands with the whole window in view.
            if focusRegion != nil {
                focusRegion = nil
                cueFocus("none", over: 0.5, steady: false)
            }
            // A beat with the whole message on screen, as a hand pauses before Return.
            try await sleep(.seconds(0.55))
            cue("enter")
            let date = now
            // Whatever the scenario put in the composer goes with the message, the way pressing
            // Return does, so a film can show a file being attached and then sent.
            let staged = store.pendingAttachments(for: conversation.id).map(\.id)
            let named = try scenario.importAttachments(
                typing.attachments, into: conversation.id, repository: repository, now: date)
            let message = try repository.sendUserMessage(conversationID: conversation.id, body: typing.text,
                attachmentIDs: staged + named, now: date)
            store.clearDraft(for: conversation.id)
            remember(message, as: typing.key)
            store.refreshTranscripts()
            runtime.notify(store.participants(for: conversation), repository: repository)
        }
        if let react = step.react, let message = messages[react.message] {
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                author: agent.map { .agent($0.id) } ?? .user, emoji: react.emoji, present: react.remove != true, now: now)
            store.refreshTranscripts()
        }
        if let stream = step.stream, let agent {
            let log = runtime.activity.log(for: agent.id), id = "scenario-\(UUID().uuidString)"
            var rest = Substring(stream.text)
            while !rest.isEmpty {
                log.record(.init(title: "Output", detail: String(rest.prefix(stream.chunk ?? 12)), streamID: id, appending: true), at: now)
                rest = rest.dropFirst(stream.chunk ?? 12)
                try await sleep(.seconds(stream.interval ?? 0.05))
            }
        }
        if let call = step.toolCall, let agent {
            // The titles the activity parser gives a harness's own command events.
            let log = runtime.activity.log(for: agent.id), id = "scenario-\(UUID().uuidString)"
            log.record(.init(title: call.title ?? "Running command", detail: call.input, streamID: id), at: now)
            try await sleep(.seconds(call.duration ?? 0.8))
            if let exit = call.exit { log.record(.init(title: "Command completed (exit \(exit))", detail: call.input, streamID: id), at: now) }
            if let output = call.output { log.record(.init(title: "Tool output", detail: output, streamID: id + ":output"), at: now) }
        }
        if let region = step.focus {
            focusRegion = region == "none" ? nil : region
            cueFocus(region, over: 0.9, steady: false)
        }
        if let error = step.error { store.errorMessage = error }
        if let present = step.present {
            apply(present)
            await arrangeWindows(present, initial: false)
        }
        switch step.waitFor {
        case .key: guard await answer(.key) else { return false }
        case .userMessage:
            guard let agent else { return true }
            let seen = arrivals[agent.id, default: 0]
            guard await answer(.userMessage(bot: step.agent ?? "")) else { return false }
            if takesShots, let id = conversation?.id {
                // Nobody types during a capture run, so the draft on screen is sent for them.
                guard !store.draft(for: id).isEmpty || !store.pendingAttachments(for: id).isEmpty else { break }
                store.sendDraft(to: id)
            }
            while arrivals[agent.id, default: 0] == seen { await withCheckedContinuation { arrivalWaiters.append($0) } }
        case nil: break
        }
        if let shot = step.capture { return await answer(.shot(shot)) }
        return true
    }

    /// Tells whoever is recording what to move in on. The move itself is made afterwards, on the film.
    private func cueFocus(_ region: String, over move: Double, steady: Bool) {
        guard takesShots, let window = mainWindow,
              let line = ScenarioCue.focus(region, in: window, stage: filmStage, over: move, steady: steady) else { return }
        write(line)
    }

    /// Tells whoever is recording that something just made a noise, and when. Only a
    /// capture run has a sound track to put it on.
    private func cue(_ name: String) {
        guard takesShots else { return }
        if let soundCue { soundCue(name); return }
        write(ScenarioCue.sound(name))
    }

    private var messages: [String: ChatMessage] { seeded.messages.merging(liveMessages) { $1 } }
    private func remember(_ message: ChatMessage, as key: String?) {
        if let key { liveMessages[key] = message }
    }

    /// Scenarios > Next Step, or a line from the terminal.
    func nextStep() { terminal.nextStep() }

    private func answer(_ pause: Pause) async -> Bool {
        if let answer = self.pause { return await answer(pause) }
        switch pause {
        case .userMessage: break
        case .key:
            // A capture run has nobody at the keyboard.
            guard !takesShots else { break }
            write("SCENARIO WAITING choose Scenarios > Next Step, or press Return here")
            await terminal.awaitKey()
        case .shot(let name):
            guard takesShots, !terminal.ended else { break }
            // Let the last change settle on screen before it is photographed.
            try? await Task.sleep(for: .milliseconds(700))
            // A patch open for review is what the shot is of; otherwise the main window.
            guard let window = store.attachmentWindows.frontmost ?? mainWindow, let region = mainWindowRegion else { break }
            write("SCENARIO SHOT \(name) id=\(window.windowNumber) rect=\(region)")
            await terminal.awaitAnswer()
        }
        return true
    }

    private var mainWindowRegion: String? { ScenarioCue.region(stage: filmStage, window: mainWindow) }

    /// Ends a capture run. The script answers once its recorder has stopped, so the window is still up on the last frame.
    func announceDone() async {
        write("SCENARIO DONE")
        await terminal.awaitAnswer()
    }

    /// Tells the script the window is up and where. A capture run waits for the answer, so a recording can start first.
    func announceReady() async {
        write("SCENARIO READY rect=\(mainWindowRegion ?? "none") \(scenario.title)")
        guard takesShots else { return }
        await terminal.awaitAnswer()
    }

    // MARK: Presentation

    /// The part of a presentation that is state in the store. Windows follow in `arrangeWindows`.
    func apply(_ present: Scenario.Presentation) {
        if let id = present.select.flatMap({ seeded.conversations[$0]?.id }) { store.selectedConversationID = id }
        if let search = present.search { store.searchText = search }
        if let id = store.selectedConversationID {
            if let draft = present.draft { store.setDraft(draft, for: id) }
            for path in present.draftAttachments ?? [] {
                if let url = try? scenario.media(path) { store.importAttachment(from: url, into: id) }
            }
        }
        guard let sheet = present.sheet else { return }
        store.creationSheet = sheet.newBot == true ? .bot : (sheet.newGroup == true ? .group : nil)
        store.agentBeingEdited = sheet.editBot.flatMap { seeded.agents[$0] }
        store.groupBeingEdited = sheet.groupInfo.flatMap { seeded.conversations[$0] }
        store.backgroundBeingEdited = sheet.background.flatMap { seeded.conversations[$0] }
    }

    var mainWindow: NSWindow? {
        NSApp?.windows.first { $0.title == NoodleAppIdentity.name && $0.contentViewController != nil && !($0 is NSPanel) }
    }

    /// Needs the running app. The first presentation's conversation windows were seeded, and the app restores them itself.
    func arrangeWindows(_ present: Scenario.Presentation, initial: Bool) async {
        for _ in 0..<100 where mainWindow == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let window = mainWindow else { return }
        if let frame = present.window {
            let origin = frame.origin ?? [Double(window.frame.minX - ScenarioSupport.screen.minX), Double(ScenarioSupport.screen.maxY - window.frame.maxY)]
            window.setFrame(ScenarioSupport.rect([origin[0], origin[1], frame.size[0], frame.size[1]]), display: true)
        }
        if let sidebar = present.sidebar, let item = ScenarioSupport.splitController(in: window.contentView)?.splitViewItems.first {
            item.isCollapsed = sidebar == .hidden
        }
        for extra in present.windows ?? [] {
            if let agent = extra.activity.flatMap({ seeded.agents[$0] }) { store.showActivity(for: agent) }
            if let tab = extra.settings.flatMap({ Scenario.settingsTabs[$0] }) {
                store.selectedSettingsTab = tab
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            if !initial, let id = extra.conversation.flatMap({ seeded.conversations[$0]?.id }) {
                if extra.floating == true { store.floatConversation(id) } else { store.dockConversation(id) }
            }
            if let message = extra.attachment.flatMap({ messages[$0] }) {
                let attachments = store.attachments(for: message)
                if let attachment = attachments.first(where: \.isPatchFile),
                   let patch = PatchCache.patchNow(at: store.attachmentFileURL(attachment)) {
                    if let viewed = extra.viewed { store.saveViewedPatchFiles(Set(viewed), for: attachment) }
                    store.attachmentWindows.open(attachment, patch: patch, store: store, frame: extra.frame.map(ScenarioSupport.rect))
                    store.attachmentWindows.model(for: attachment)?.expanded.formUnion(extra.expanded ?? [])
                } else if let attachment = attachments.first(where: \.opensAsDocument) {
                    store.attachmentWindows.openDocument(attachment, store: store, frame: extra.frame.map(ScenarioSupport.rect),
                                                         source: extra.source)
                }
            }
        }
        if initial {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        // Only when the app first appears. A later presentation that set the film up again would
        // put the opening card back and leave the app concealed behind it for the rest of the film.
        // The backdrop and the cards are staged for a recording only; watched, the app stays on the desktop.
        if initial, takesShots, let film = scenario.film {
            let stage = filmStage ?? ScenarioFilmStage(film: film, title: scenario.title, media: scenario.media, mark: NoodleWordmark.filmMark)
            filmStage = stage
            stage.open(on: window)
        }
    }

    // MARK: Terminal

    private func write(_ line: String) { terminal.write(line) }

    /// scripts/scenario.sh answers a shot with a newline once it is taken; at `waitFor: key` Return does what Next Step does.
    private func readTerminal() { terminal.start() }
}

// MARK: - Launch, picker and menu

extension ScenarioSession {
    /// Where `scripts/scenario.sh` said the scenarios are.
    static var scenariosRoot: URL? { ScenarioLauncher.scenariosRoot(key: "NoodleScenariosRoot") }

    static func listings(in root: URL?) -> [ScenarioListing] {
        ScenarioLauncher.listings(in: root) { (try Scenario.load(from: $0).title, nil) }
    }

    /// The launch argument first, then the choice made in the app, unless the launch asks for the picker.
    static func selection(_ checks: LaunchChecks, pointer: URL) -> String? {
        ScenarioLauncher.selection(argument: checks.value(after: DevelopmentHook.scenario),
                                   picker: checks.contains(DevelopmentHook.scenarioPicker), pointer: pointer)
    }

    /// The store for this launch, or nil outside the scenarios bundle, where the app opens as usual.
    static func launch(_ checks: LaunchChecks) -> NoodleStore? {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("SCENARIO FAILED \(message)\n".utf8))
            Darwin.exit(1)
        }
        let argument = checks.value(after: DevelopmentHook.scenario)
        guard isIsolated(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            if argument != nil { fail("Scenarios run only in the bundle scripts/scenario.sh makes (\(bundleIdentifier)).") }
            return nil
        }
        // Each launch starts from nothing: the last scenario's preferences and workspace are discarded.
        // A relaunch from the menu passes no arguments, so the locale the script asks for is kept here.
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.set("en_US", forKey: "AppleLocale")
        defaults.set(["en"], forKey: "AppleLanguages")
        let runs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scenario", isDirectory: true)
        try? FileManager.default.removeItem(at: runs)

        func open(_ scenario: Scenario) throws -> ScenarioSession {
            // The instance this one replaces may still be writing as it quits, so no two launches share a folder.
            let session = try ScenarioSession(scenario, root: runs.appendingPathComponent(UUID().uuidString, isDirectory: true), defaults: defaults)
            active = session
            return session
        }

        if let selection = selection(checks, pointer: ScenarioLauncher.pointerURL) {
            do {
                guard let folder = ScenarioLauncher.folder(for: selection, root: scenariosRoot) else { throw ScenarioError("The bundle does not say where the scenarios are.") }
                var scenario = try Scenario.load(from: folder)
                try scenario.resize(checks)
                try scenario.adjustFilm(checks)
                let session = try open(scenario)
                session.selection = selection
                try? ScenarioLauncher.select(selection, pointer: ScenarioLauncher.pointerURL)
                session.takesShots = checks.contains(DevelopmentHook.scenarioShots)
                session.readTerminal()
                session.store.startMonitoring()
                let benchmark = checks.value(after: DevelopmentHook.scenarioBenchmark)
                    ?? (checks.contains(DevelopmentHook.scenarioBenchmark) ? "all" : nil)
                Task { @MainActor in
                    do { try await session.start(benchmark: benchmark) } catch { fail(error.localizedDescription) }
                }
                return session.store
            } catch {
                // The script is told. A choice made in the app goes back to the picker, which says what is wrong.
                if argument != nil { fail(error.localizedDescription) }
                try? ScenarioLauncher.select(nil, pointer: ScenarioLauncher.pointerURL)
            }
        }

        // Nothing is loaded: an empty workspace, with the picker standing in for the main window.
        var nothing = Scenario(version: 1, title: "Scenarios", harnesses: [:], agents: [])
        nothing.settings = [FirstBotSetup.dismissedKey: .bool(true)]
        do {
            let session = try open(nothing)
            Task { @MainActor in
                for _ in 0..<250 where session.mainWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
                session.mainWindow?.orderOut(nil)
                session.showPicker()
            }
            return session.store
        } catch { fail(error.localizedDescription) }
    }

    static func relaunch(into name: String?) {
        guard isIsolated(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        ScenarioLauncher.relaunch(into: name)
    }

    func showPicker() { ScenarioLauncher.showPicker(Self.listings(in: Self.scenariosRoot)) }

    func revealInFinder() {
        guard let folder = selection == nil ? Self.scenariosRoot : scenario.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The Scenarios menu, which only the scenarios bundle shows.
struct ScenarioCommands: Commands {
    var body: some Commands {
        if let session = ScenarioSession.active {
            ScenarioMenu(listings: ScenarioSession.listings(in: ScenarioSession.scenariosRoot),
                         loaded: session.selection == nil ? nil : session.scenario.folder, selection: session.selection,
                         nextStep: session.nextStep, showPicker: session.showPicker, reveal: session.revealInFinder)
        }
    }
}

#endif
