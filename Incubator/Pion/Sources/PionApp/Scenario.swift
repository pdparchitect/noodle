#if PION_DEV_HOOKS
import AppKit
import NoodleCore
import PionCore
import SwiftUI

/// A scripted Pion, in the shape of Noodle's scenarios: agents, conversations and a timeline, with each
/// conversation optionally an Investigation and its case record. Scenarios run only in the bundle
/// scripts/scenario.sh derives from Pion Dev, which has no network and its own container.
struct PionScenario: Decodable {
    struct Agent: Decodable {
        let key: String
        let name: String
        var harness: String?
        var model: String?
        var description: String?
        var backstory: String?
        var avatar: Avatar?
        var status: Status?
        /// The agent's tasks as the scenario starts, oldest first.
        var tasks: [TaskEntry]?
        struct Avatar: Decodable { var symbol: String?; var color: Int? }
    }

    /// An agent's task, as in Noodle's scenarios. `in` is a conversation key, the agent's own conversation
    /// when left out; `on` is "user" or an agent key, for a waiting task.
    struct TaskEntry: Decodable {
        let title: String
        var `in`: String?
        var state: AgentTask.State?
        var on: String?
        var note: String?
    }

    /// A web page's card as it shows without the network: its title, and a picture in the scenario's folder.
    struct LinkPreview: Decodable { let url: URL; var title: String?; var image: String? }

    struct Status: Decodable {
        var phase: AgentRuntimePhase
        var detail: String?
    }

    struct Message: Decodable { let at: String; let from: String; let text: String }

    /// A preference, as View options keep them: true or false, a number, or a word.
    enum Setting: Decodable {
        case bool(Bool), number(Double), text(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else { self = .text(try value.decode(String.self)) }
        }
        var value: Any {
            switch self {
            case .bool(let value): value
            case .number(let value): value
            case .text(let value): value
            }
        }
    }

    struct Conversation: Decodable {
        let key: String
        var group: Group?
        /// An agent's own conversation with the champion.
        var direct: String?
        var messages: [Message]?
        var investigation: InvestigationRecord?
        /// Pinned in the order the conversations are listed.
        var pinned: Bool?
        struct Group: Decodable { let name: String; var description: String?; let members: [String] }
    }

    struct InvestigationRecord: Decodable {
        var number: Int?
        let title: String
        var objective: String?
        var severity: Investigation.Severity?
        var status: Investigation.Status?
        var outcome: Investigation.Outcome?
        var closingNote: String?
        /// The agent the champion made the lead; none when left out.
        var lead: String?
        var source: String?
        let opened: String
        var `case`: Case?
    }

    struct Case: Decodable {
        var entities: [Entity]?
        var evidence: [Evidence]?
        var findings: [Finding]?
    }

    struct Entity: Decodable { let kind: CaseRecord.Entity.Kind; let name: String; var detail: String?; var at: String?; var by: String? }
    struct Evidence: Decodable { let source: String; let method: String; let result: String; var at: String?; var by: String? }
    struct Finding: Decodable {
        let claim: String; let evidence: [String]; let confidence: CaseRecord.Finding.Confidence
        var entities: [String]?; var at: String?; var by: String?
    }
    struct Present: Decodable {
        var window: Window?
        var select: String?
        var inspector: String?
        /// edit, new-investigation, new-group, new-agent, or none to dismiss.
        var sheet: String?
        struct Window: Decodable { let size: [Double] }
    }

    /// One moment of the timeline. `wait` pauses first; then whatever else is set happens.
    struct Step: Decodable {
        var wait: Double?
        var waitFor: String?
        var agent: String?
        var `in`: String?
        var status: Status?
        var reply: Content?
        var say: Content?
        var entity: Entity?
        var evidence: Evidence?
        var finding: Finding?
        var investigationStatus: Investigation.Status?
        var present: Present?
        var settings: [String: Setting]?
        var capture: String?
        struct Content: Decodable { let text: String }
    }

    let version: Int
    let title: String
    var summary: String?
    var clock: String?
    var appearance: String?
    var champion: String?
    var settings: [String: Setting]?
    let agents: [Agent]
    var conversations: [Conversation]?
    var present: Present?
    var timeline: [Step]?
    var linkPreviews: [LinkPreview]?

    var folder = URL(fileURLWithPath: "/")
    private enum CodingKeys: String, CodingKey {
        case version, title, summary, clock, appearance, champion, settings, agents, conversations, present, timeline, linkPreviews
    }

    static func load(from folder: URL) throws -> PionScenario {
        do {
            var scenario = try JSONDecoder().decode(PionScenario.self, from: Data(contentsOf: folder.appendingPathComponent("scenario.json")))
            scenario.folder = folder
            try scenario.validate()
            return scenario
        } catch let error as DecodingError {
            throw CaseError("scenario.json: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined().trimmingCharacters(in: ["."])
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context)) is missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw CaseError(message) } }
        let agentKeys = Set(agents.map(\.key)), conversationKeys = Set((conversations ?? []).map(\.key))
        try require(agentKeys.count == agents.count, "Two agents share a key.")
        func author(_ key: String?, _ context: String) throws {
            guard let key else { return }
            try require(key == "user" || agentKeys.contains(key), "\(context) names an unknown agent \(key).")
        }
        for conversation in conversations ?? [] {
            try require((conversation.group == nil) != (conversation.direct == nil), "\(conversation.key) is a group or a direct conversation.")
            for member in conversation.group?.members ?? [] { try author(member, conversation.key) }
            try author(conversation.direct, conversation.key)
            for message in conversation.messages ?? [] { try author(message.from, conversation.key) }
            if let investigation = conversation.investigation {
                try require(conversation.group != nil, "\(conversation.key): only a group is an Investigation.")
                if let lead = investigation.lead { try author(lead, conversation.key) }
            }
        }
        for agent in agents {
            for task in agent.tasks ?? [] {
                let name = "\(agent.key)'s task \(task.title)"
                try require(!task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(agent.key) has a task without a title.")
                if let key = task.in {
                    let members = (conversations ?? []).first { $0.key == key }.map { ($0.group?.members ?? []) + [$0.direct, $0.investigation?.lead].compactMap { $0 } }
                    try require(members != nil, "\(name) names an unknown conversation \(key).")
                    try require(members?.contains(agent.key) == true, "\(name) is in \(key), which \(agent.key) is not in.")
                }
                if let on = task.on {
                    try require(on == "user" || agentKeys.contains(on), "\(name) waits on an unknown agent \(on).")
                    try require((task.state ?? .waiting) == .waiting, "\(name): only a waiting task waits on someone.")
                }
            }
        }
        for preview in linkPreviews ?? [] {
            if let image = preview.image {
                try require(FileManager.default.fileExists(atPath: folder.appendingPathComponent(image).path), "No picture \(image) for \(preview.url).")
            }
        }
        for (index, step) in (timeline ?? []).enumerated() {
            if let key = step.in { try require(conversationKeys.contains(key), "Step \(index + 1) names an unknown conversation \(key).") }
            try author(step.agent, "Step \(index + 1)")
        }
    }
}

/// Times in scenario files: HH:MM today, or -2d HH:MM some days before.
// MARK: - Session

@MainActor final class ScenarioSession {
    static let bundleIdentifier = "com.pdparchitect.pion.scenarios"
    private(set) static var active: ScenarioSession?

    let scenario: PionScenario?
    let model: PionModel
    let selection: String?
    weak var window: WindowState?
    private var agentIDs: [String: UUID] = [:]
    private var conversationIDs: [String: UUID] = [:]
    private var keyWaiters: [CheckedContinuation<Void, Never>] = []
    private var lineWaiters: [CheckedContinuation<Void, Never>] = []
    private var takesShots = false

    private init(scenario: PionScenario?, selection: String?, root: URL) throws {
        self.scenario = scenario
        self.selection = selection
        model = PionModel(root: root, messenger: nil, isScripted: true)
        try model.repository.prepare()
        if let scenario { try seed(scenario) }
    }

    // MARK: Launch

    static var scenariosRoot: URL? { ScenarioLauncher.scenariosRoot(key: "PionScenariosRoot") }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The session for this launch, or nil outside the scenarios bundle, where Pion opens as usual.
    static func launch() -> ScenarioSession? {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("SCENARIO FAILED \(message)\n".utf8))
            exit(1)
        }
        let argument = argument(after: "--scenario")
        guard Bundle.main.bundleIdentifier == bundleIdentifier else {
            if argument != nil { fail("Scenarios run only in the bundle scripts/scenario.sh makes (\(bundleIdentifier)).") }
            return nil
        }
        // Each launch starts from nothing.
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        let runs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scenario", isDirectory: true)
        try? FileManager.default.removeItem(at: runs)
        let root = runs.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Pion", isDirectory: true)
        let pointer = ScenarioLauncher.pointerURL
        if let selection = ScenarioLauncher.selection(argument: argument, picker: CommandLine.arguments.contains("--scenario-picker"),
                                                      pointer: pointer) {
            do {
                guard let folder = ScenarioLauncher.folder(for: selection, root: scenariosRoot) else {
                    throw ScenarioError("The bundle does not say where the scenarios are.")
                }
                let session = try ScenarioSession(scenario: try PionScenario.load(from: folder), selection: selection, root: root)
                session.takesShots = CommandLine.arguments.contains("--scenario-shots")
                active = session
                try? ScenarioLauncher.select(selection, pointer: pointer)
                return session
            } catch {
                if argument != nil { fail(error.localizedDescription) }
                try? ScenarioLauncher.select(nil, pointer: pointer)
            }
        }
        do {
            let session = try ScenarioSession(scenario: nil, selection: nil, root: root)
            active = session
            return session
        } catch { fail(error.localizedDescription) }
    }

    static func relaunch(into name: String?) { ScenarioLauncher.relaunch(into: name) }

    // MARK: Seed

    private func seed(_ scenario: PionScenario) throws {
        let clock = try scenario.clock.map { try ScenarioTime.date($0, clock: Date()) } ?? Date()
        ScenarioClock.offset = clock.timeIntervalSinceNow
        model.scriptedChampion = scenario.champion ?? "Avery Lin"
        for (key, setting) in scenario.settings ?? [:] { UserDefaults.standard.set(setting.value, forKey: key) }
        if scenario.appearance == "dark" { NSApp?.appearance = NSAppearance(named: .darkAqua) }
        for agent in scenario.agents {
            let record = try model.createAgent(name: agent.name, description: agent.description, instructions: agent.backstory ?? "",
                                               provider: agent.harness.flatMap(HarnessProvider.init(rawValue:)), model: agent.model,
                                               symbol: agent.avatar?.symbol, color: agent.avatar?.color ?? agentIDs.count)
            agentIDs[agent.key] = record.id
            if let detail = agent.status?.detail { _ = try model.repository.setAgentStatus(String(detail.prefix(AgentRecord.statusLimit)), agentID: record.id, setAt: clock) }
            model.scriptedPhases[record.id] = agent.status?.phase ?? .ready
        }
        model.reload()
        let agents = try model.repository.loadAgents()
        for conversation in scenario.conversations ?? [] {
            let id: UUID
            if let key = conversation.direct, let agent = model.agents.first(where: { $0.id == agentIDs[key] }) {
                guard let direct = model.directConversation(of: agent) else { continue }
                id = direct.id
            } else if let group = conversation.group, let record = conversation.investigation {
                let opened = try ScenarioTime.date(record.opened, clock: clock)
                let number = record.number ?? 1
                let lead = record.lead.flatMap { agentIDs[$0] }
                let members = Set(group.members.compactMap { agentIDs[$0] }).union(lead.map { [$0] } ?? [])
                id = try model.repository.createGroup(named: PionModel.groupName(number: number, title: record.title), publicDescription: record.objective,
                                                      participantIDs: Array(members), existingAgents: agents, leadID: lead, now: opened).id
                _ = try model.store.open(id: id, title: record.title, objective: record.objective ?? "",
                                         severity: record.severity, champion: model.champion,
                                         source: record.source, number: number, now: opened)
            } else if let group = conversation.group {
                id = try model.repository.createGroup(named: group.name, publicDescription: group.description,
                                                      participantIDs: group.members.compactMap { agentIDs[$0] }, existingAgents: agents,
                                                      now: clock.addingTimeInterval(-86_400 * 30)).id
            } else { continue }
            conversationIDs[conversation.key] = id
            for message in conversation.messages ?? [] {
                try model.repository.append(ChatMessage(conversationID: id, author: author(message.from), body: message.text,
                                                        createdAt: try ScenarioTime.date(message.at, clock: clock), delivery: .delivered))
            }
            if let record = conversation.investigation {
                let opened = try ScenarioTime.date(record.opened, clock: clock)
                for item in record.case?.entities ?? [] { try add(item, to: id, clock: clock, fallback: opened) }
                for item in record.case?.evidence ?? [] { try add(item, to: id, clock: clock, fallback: opened) }
                for item in record.case?.findings ?? [] { try add(item, to: id, clock: clock, fallback: opened) }
                if let status = record.status, status != .open {
                    let at = clock.addingTimeInterval(-60)
                    if status == .closed {
                        try model.store.setStatus(.closed, of: id, by: .champion(model.champion), outcome: record.outcome ?? .resolved,
                                                  note: record.closingNote, now: at)
                    } else {
                        let actor = record.lead.flatMap { agentIDs[$0] }.map(CaseActor.agent) ?? .champion(model.champion)
                        try model.store.setStatus(status, of: id, by: actor, now: at)
                    }
                }
            }
        }
        try model.repository.savePinnedConversationIDs((scenario.conversations ?? []).filter { $0.pinned == true }.compactMap { conversationIDs[$0.key] })
        for agent in scenario.agents {
            guard let agentID = agentIDs[agent.key] else { continue }
            for task in agent.tasks ?? [] {
                let conversation = task.in.flatMap { conversationIDs[$0] }
                    ?? model.agents.first { $0.id == agentID }.flatMap { model.directConversation(of: $0) }?.id
                let id = try model.repository.addTask(agentID: agentID, title: task.title, conversationID: conversation, note: task.note, now: clock).id
                let waitingOn = task.on.map { $0 == "user" ? MessageAuthor.user : agentIDs[$0].map(MessageAuthor.agent) ?? .user }
                guard task.state != nil || waitingOn != nil else { continue }
                _ = try model.repository.updateTask(agentID: agentID, id: id, state: task.state ?? .waiting, waitingOn: waitingOn, now: clock)
            }
        }
        for preview in scenario.linkPreviews ?? [] {
            LinkPreviewMetadataCache.shared.remember(preview.url, title: preview.title,
                                                     image: preview.image.flatMap { NSImage(contentsOf: scenario.folder.appendingPathComponent($0)) })
        }
        model.refresh()
        // Everything seeded counts as read, so the scenario opens as its author left it.
        for conversation in model.conversations { model.markRead(conversation.id) }
    }

    private func author(_ key: String) -> MessageAuthor { agentIDs[key].map(MessageAuthor.agent) ?? .user }

    private func by(_ key: String?, _ id: UUID) -> CaseActor {
        if key == "user" { return .champion(model.champion) }
        return key.flatMap { agentIDs[$0] }.map(CaseActor.agent)
            ?? model.conversation(id)?.lead.map(CaseActor.agent) ?? .champion(model.champion)
    }

    private func time(_ text: String?, clock: Date, fallback: Date) throws -> Date {
        try text.map { try ScenarioTime.date($0, clock: clock) } ?? fallback
    }

    private func add(_ entity: PionScenario.Entity, to id: UUID, clock: Date, fallback: Date) throws {
        let at = try time(entity.at, clock: clock, fallback: fallback), actor = by(entity.by, id)
        _ = try model.store.updateCase(id, by: actor, now: at) { record, _ in
            let item = record.record(entity: entity.kind, name: entity.name, detail: entity.detail, by: actor, at: at)
            return ((), "entity", "\(item.id) \(entity.kind.rawValue) \(entity.name)")
        }
    }

    private func add(_ evidence: PionScenario.Evidence, to id: UUID, clock: Date, fallback: Date) throws {
        let at = try time(evidence.at, clock: clock, fallback: fallback), actor = by(evidence.by, id)
        _ = try model.store.updateCase(id, by: actor, now: at) { record, _ in
            let item = record.record(evidenceFrom: evidence.source, method: evidence.method, result: evidence.result, by: actor, at: at)
            return ((), "evidence", "\(item.id) from \(evidence.source)")
        }
    }

    private func add(_ finding: PionScenario.Finding, to id: UUID, clock: Date, fallback: Date) throws {
        let at = try time(finding.at, clock: clock, fallback: fallback), actor = by(finding.by, id)
        _ = try model.store.updateCase(id, by: actor, now: at) { record, _ in
            let item = try record.record(finding: finding.claim, evidence: finding.evidence, confidence: finding.confidence,
                                         entities: finding.entities ?? [], by: actor, at: at)
            return ((), "finding", "\(item.id) \(finding.confidence.rawValue): \(finding.claim)")
        }
    }

    // MARK: Playing

    func begin() {
        guard let scenario else {
            Task { @MainActor in
                for _ in 0..<100 where mainWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
                mainWindow?.orderOut(nil)
                showPicker()
            }
            return
        }
        if let present = scenario.present { apply(present) }
        readTerminal()
        Task { @MainActor in
            for _ in 0..<150 where mainWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
            if let size = scenario.present?.window?.size, size.count == 2, let window = mainWindow {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            await announce("SCENARIO READY \(frame) \(scenario.title)")
            for (index, step) in (scenario.timeline ?? []).enumerated() {
                do { try await perform(step) }
                catch { FileHandle.standardError.write(Data("SCENARIO STEP \(index + 1) FAILED \(error.localizedDescription)\n".utf8)) }
                model.refresh()
            }
            await announce("SCENARIO DONE")
            if takesShots { NSApp.terminate(nil) }
        }
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !ScenarioLauncher.isPicker($0) && $0.isVisible }
            ?? NSApp.windows.first { $0.canBecomeMain && !ScenarioLauncher.isPicker($0) }
    }

    /// The main window in screen coordinates with the origin at the top left, as screencapture takes it.
    private var frame: String {
        guard let window = mainWindow, let screen = window.screen ?? NSScreen.main else { return "rect=none" }
        let top = screen.frame.maxY - window.frame.maxY
        return "rect=\(Int(window.frame.minX)),\(Int(top)),\(Int(window.frame.width)),\(Int(window.frame.height))"
    }

    private func perform(_ step: PionScenario.Step) async throws {
        if let wait = step.wait { try await Task.sleep(for: .seconds(takesShots ? min(wait, 0.3) : wait)) }
        if step.waitFor == "key", !takesShots { await withCheckedContinuation { keyWaiters.append($0) } }
        let now = ScenarioClock.now
        let agent = step.agent.flatMap { agentIDs[$0] }
        let conversation = step.in.flatMap { conversationIDs[$0] }
        if let status = step.status, let agent {
            model.scriptedPhases[agent] = status.phase
            _ = try? model.repository.setAgentStatus(status.detail.map { String($0.prefix(AgentRecord.statusLimit)) }, agentID: agent, setAt: now)
        }
        if let reply = step.reply, let agent, let conversation {
            let before = model.scriptedPhases[agent]
            model.scriptedPhases[agent] = .working
            model.refresh()
            try await Task.sleep(for: .seconds(takesShots ? 0.15 : 1.2))
            model.scriptedPhases[agent] = before == .working ? .working : .ready
            _ = try model.repository.sendAgentMessage(agentID: agent, conversationID: conversation, body: reply.text, now: ScenarioClock.now)
        }
        if let say = step.say, let conversation { try model.send(say.text, in: conversation) }
        if let conversation, model.investigation(conversation) != nil {
            let actor = step.agent
            if let item = step.entity { try add(PionScenario.Entity(kind: item.kind, name: item.name, detail: item.detail, by: item.by ?? actor), to: conversation, clock: now, fallback: now) }
            if let item = step.evidence { var copy = item; copy.by = item.by ?? actor; try add(copy, to: conversation, clock: now, fallback: now) }
            if let item = step.finding { var copy = item; copy.by = item.by ?? actor; try add(copy, to: conversation, clock: now, fallback: now) }
            if let status = step.investigationStatus { try model.store.setStatus(status, of: conversation, by: by(actor, conversation), now: now) }
        }
        if let present = step.present { apply(present) }
        for (key, setting) in step.settings ?? [:] { UserDefaults.standard.set(setting.value, forKey: key) }
        if let name = step.capture {
            model.refresh()
            try await Task.sleep(for: .milliseconds(450))
            await announce("SCENARIO SHOT \(name) id=\(mainWindow?.windowNumber ?? 0) \(frame) drawn=\(drawn(name)?.path ?? "none")")
        }
    }

    /// The window as Pion draws it, for when the screen cannot be photographed, as while it is locked.
    /// Window materials such as the sidebar's draw blank, so it is a check of layout, not a picture to show.
    private func drawn(_ name: String) -> URL? {
        guard let view = mainWindow?.contentView?.superview ?? mainWindow?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { return nil }
        return file
    }

    private func apply(_ present: PionScenario.Present) {
        if let key = present.select, let id = conversationIDs[key] { model.selection = id }
        if let sheet = present.sheet, let window {
            switch sheet {
            case "edit": if let conversation = model.conversation(model.selection) { window.edit(conversation, in: model) }
            case "new-investigation": window.sheet = .newInvestigation
            case "new-group": window.sheet = .newGroup
            case "new-agent": window.sheet = .newAgent
            case "close": if let investigation = model.investigation(model.selection) { window.sheet = .close(investigation) }
            default: window.sheet = nil
            }
        }
        if let inspector = present.inspector {
            window?.showsInspector = inspector != "hidden"
            window?.inspectorTab = inspector == "audit" ? .audit : .caseRecord
        }
    }

    /// Tells scripts/scenario.sh, and when it is capturing, waits for its empty line before going on.
    private func announce(_ line: String) async {
        print(line)
        fflush(stdout)
        guard takesShots else { return }
        await withCheckedContinuation { lineWaiters.append($0) }
    }

    /// Next Step from the menu, or a line from the terminal.
    func nextStep() {
        let waiters = keyWaiters
        keyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func readTerminal() {
        guard CommandLine.arguments.contains("--scenario") else { return }
        Thread.detachNewThread {
            while readLine() != nil {
                Task { @MainActor in
                    guard let session = ScenarioSession.active else { return }
                    if !session.lineWaiters.isEmpty {
                        let waiter = session.lineWaiters.removeFirst()
                        waiter.resume()
                    } else { session.nextStep() }
                }
            }
        }
    }

    // MARK: Picker

    static func listings() -> [ScenarioListing] {
        ScenarioLauncher.listings(in: scenariosRoot) { folder in
            let scenario = try PionScenario.load(from: folder)
            return (scenario.title, scenario.summary)
        }
    }

    func showPicker() { ScenarioLauncher.showPicker(Self.listings()) }

    func revealInFinder() {
        guard let folder = scenario?.folder ?? Self.scenariosRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The Scenarios menu, which only the scenarios bundle shows.
struct ScenarioCommands: Commands {
    var body: some Commands {
        if let session = ScenarioSession.active {
            ScenarioMenu(listings: ScenarioSession.listings(), loaded: session.scenario?.folder, selection: session.selection,
                         nextStep: session.nextStep, showPicker: session.showPicker, reveal: session.revealInFinder)
        }
    }
}
#endif
