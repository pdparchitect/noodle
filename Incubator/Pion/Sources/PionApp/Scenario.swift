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
        struct Avatar: Decodable { var symbol: String?; var color: Int? }
    }

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
        struct Group: Decodable { let name: String; var description: String?; let members: [String] }
    }

    struct InvestigationRecord: Decodable {
        var number: Int?
        let title: String
        var objective: String?
        var scope: [String]?
        var severity: Investigation.Severity?
        var status: Investigation.Status?
        var outcome: Investigation.Outcome?
        var closingNote: String?
        let lead: String
        var source: String?
        let opened: String
        var `case`: Case?
    }

    struct Case: Decodable {
        var entities: [Entity]?
        var evidence: [Evidence]?
        var findings: [Finding]?
        var actions: [Action]?
    }

    struct Entity: Decodable { let kind: CaseRecord.Entity.Kind; let name: String; var detail: String?; var at: String?; var by: String? }
    struct Evidence: Decodable { let source: String; let method: String; let result: String; var at: String?; var by: String? }
    struct Finding: Decodable {
        let claim: String; let evidence: [String]; let confidence: CaseRecord.Finding.Confidence
        var entities: [String]?; var at: String?; var by: String?
    }
    struct Action: Decodable {
        let operation: String; let targets: [String]; let rationale: String; let effect: String; let undo: String
        var evidence: [String]?; var state: CaseRecord.ProposedAction.State?; var note: String?; var at: String?; var by: String?
    }

    struct Present: Decodable {
        var window: Window?
        var select: String?
        var inspector: String?
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
        var propose: Action?
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
    var protectedAssets: [String]?
    var settings: [String: Setting]?
    let agents: [Agent]
    var conversations: [Conversation]?
    var present: Present?
    var timeline: [Step]?

    var folder = URL(fileURLWithPath: "/")
    private enum CodingKeys: String, CodingKey {
        case version, title, summary, clock, appearance, champion, protectedAssets, settings, agents, conversations, present, timeline
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
                try author(investigation.lead, conversation.key)
            }
        }
        for (index, step) in (timeline ?? []).enumerated() {
            if let key = step.in { try require(conversationKeys.contains(key), "Step \(index + 1) names an unknown conversation \(key).") }
            try author(step.agent, "Step \(index + 1)")
        }
    }
}

/// Times in scenario files: HH:MM today, or -2d HH:MM some days before.
enum ScenarioTime {
    static func date(_ text: String, clock: Date, calendar: Calendar = .current) throws -> Date {
        var days = 0
        var time = Substring(text.trimmingCharacters(in: .whitespaces))
        if time.hasPrefix("-"), let space = time.firstIndex(of: " "), time[time.index(before: space)] == "d",
           let value = Int(time[time.index(after: time.startIndex)..<time.index(before: space)]) {
            days = value
            time = time[time.index(after: space)...]
        }
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute),
              let day = calendar.date(byAdding: .day, value: -days, to: clock),
              let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
            throw CaseError("\(text) is not a time like 03:25 or -1d 17:40.")
        }
        return date
    }
}

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
    private var pickerWindow: NSWindow?
    private var takesShots = false

    private init(scenario: PionScenario?, selection: String?, root: URL) throws {
        self.scenario = scenario
        self.selection = selection
        model = PionModel(root: root, messenger: nil, isScripted: true)
        try model.repository.prepare()
        if let scenario { try seed(scenario) }
    }

    // MARK: Launch

    static var scenariosRoot: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "PionScenariosRoot") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var pointerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("scenario-selection.txt")
    }

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
        let chosen = (try? String(contentsOf: pointerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = argument ?? (CommandLine.arguments.contains("--scenario-picker") ? nil : chosen.flatMap { $0.isEmpty ? nil : $0 })
        if let selection {
            do {
                let folder = selection.contains("/") ? URL(fileURLWithPath: selection, isDirectory: true)
                    : scenariosRoot?.appendingPathComponent(selection, isDirectory: true)
                guard let folder else { throw CaseError("The bundle does not say where the scenarios are.") }
                let session = try ScenarioSession(scenario: try PionScenario.load(from: folder), selection: selection, root: root)
                session.takesShots = CommandLine.arguments.contains("--scenario-shots")
                active = session
                try? select(selection)
                return session
            } catch {
                if argument != nil { fail(error.localizedDescription) }
                try? select(nil)
            }
        }
        do {
            let session = try ScenarioSession(scenario: nil, selection: nil, root: root)
            active = session
            return session
        } catch { fail(error.localizedDescription) }
    }

    static func select(_ name: String?) throws {
        guard let name else { try? FileManager.default.removeItem(at: pointerURL); return }
        try FileManager.default.createDirectory(at: pointerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: pointerURL, options: .atomic)
    }

    /// A sandboxed app cannot pass itself arguments, so the choice travels in the pointer file, and the
    /// bundle reopens once this copy has quit.
    static func relaunch(into name: String?) {
        do {
            try select(name)
            let pipe = Pipe(), process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec 3<&0; set -m; (cat <&3 > /dev/null; sleep 0.3; exec \"$0\" \"$1\") > /dev/null 2>&1 &",
                                 "/usr/bin/open", Bundle.main.bundleURL.path]
            process.standardInput = pipe
            try process.run()
            whileRunning = pipe.fileHandleForWriting
            NSApp.terminate(nil)
        } catch { NSSound.beep() }
    }

    private static var whileRunning: FileHandle?

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
        if let protected = scenario.protectedAssets {
            var policy = model.store.policy()
            policy.protectedAssets = protected
            try model.store.setPolicy(policy)
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
                let lead = agentIDs[record.lead]!
                let members = Set(group.members.compactMap { agentIDs[$0] }).union([lead])
                id = try model.repository.createGroup(named: PionModel.groupName(number: number, title: record.title), publicDescription: record.objective,
                                                      participantIDs: Array(members), existingAgents: agents, now: opened).id
                _ = try model.store.open(id: id, title: record.title, objective: record.objective ?? "", scope: record.scope ?? [],
                                         severity: record.severity ?? .medium, champion: model.champion, leadAgentID: lead,
                                         playbookID: nil, source: record.source, number: number, now: opened)
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
                for item in record.case?.actions ?? [] { try add(item, to: id, clock: clock, fallback: opened) }
                if let status = record.status, status != .open {
                    let at = clock.addingTimeInterval(-60)
                    if status == .closed {
                        try model.store.setStatus(.closed, of: id, by: .champion(model.champion), outcome: record.outcome ?? .resolved,
                                                  note: record.closingNote, now: at)
                    } else {
                        try model.store.setStatus(status, of: id, by: .agent(agentIDs[record.lead]!), now: at)
                    }
                }
            }
        }
        model.refresh()
        // Everything seeded counts as read, so the scenario opens as its author left it.
        for conversation in model.conversations { model.markRead(conversation.id) }
    }

    private func author(_ key: String) -> MessageAuthor { agentIDs[key].map(MessageAuthor.agent) ?? .user }

    private func by(_ key: String?, _ id: UUID) -> CaseActor {
        if key == "user" { return .champion(model.champion) }
        return key.flatMap { agentIDs[$0] }.map(CaseActor.agent)
            ?? model.store.investigation(id)?.leadAgentID.map(CaseActor.agent) ?? .policy
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

    private func add(_ action: PionScenario.Action, to id: UUID, clock: Date, fallback: Date) throws {
        let at = try time(action.at, clock: clock, fallback: fallback)
        let (proposed, _, _) = try model.store.propose(operation: action.operation, targets: action.targets, rationale: action.rationale,
                                                       expectedEffect: action.effect, undo: action.undo, evidence: action.evidence ?? [],
                                                       in: id, by: by(action.by, id), now: at)
        let decided = at.addingTimeInterval(120)
        switch action.state {
        case .approved?, .done?:
            if proposed.state == .pending {
                try model.store.decide(proposed.id, in: id, approve: true, note: action.state == .approved ? action.note : nil, by: model.champion, now: decided)
            }
            if action.state == .done { try model.store.markDone(proposed.id, in: id, note: action.note, by: model.champion, now: decided.addingTimeInterval(300)) }
        case .denied?:
            if proposed.state == .pending { try model.store.decide(proposed.id, in: id, approve: false, note: action.note, by: model.champion, now: decided) }
        default: break
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
        NSApp.windows.first { $0.canBecomeMain && $0 !== pickerWindow && $0.isVisible }
            ?? NSApp.windows.first { $0.canBecomeMain && $0 !== pickerWindow }
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
            if let item = step.propose { var copy = item; copy.by = item.by ?? actor; try add(copy, to: conversation, clock: now, fallback: now) }
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

    struct Listing: Identifiable {
        let name: String
        let folder: URL
        let title: String
        let summary: String?
        let error: String?
        var id: String { name }
    }

    static func listings() -> [Listing] {
        guard let root = scenariosRoot, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scenario.json").path) else { return nil }
            do {
                let scenario = try PionScenario.load(from: folder)
                return Listing(name: name, folder: folder, title: scenario.title, summary: scenario.summary, error: nil)
            } catch {
                return Listing(name: name, folder: folder, title: name, summary: nil, error: error.localizedDescription)
            }
        }
    }

    func showPicker() {
        if pickerWindow == nil {
            let controller = NSHostingController(rootView: ScenarioPicker(listings: Self.listings()))
            controller.title = "Scenarios"
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 420))
            window.center()
            pickerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow?.makeKeyAndOrderFront(nil)
    }

    func revealInFinder() {
        guard let folder = scenario?.folder ?? Self.scenariosRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

private struct ScenarioPicker: View {
    let listings: [ScenarioSession.Listing]
    @State private var selection: String?
    private var canLoad: Bool { listings.contains { $0.name == selection && $0.error == nil } }

    var body: some View {
        VStack(spacing: 0) {
            List(listings, selection: $selection) { listing in
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.title)
                    Text(listing.error ?? listing.summary ?? listing.name)
                        .font(.caption)
                        .foregroundStyle(listing.error == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { names in
                if let name = names.first, listings.contains(where: { $0.name == name && $0.error == nil }) { ScenarioSession.relaunch(into: name) }
            }
            .overlay { if listings.isEmpty { Text("No scenarios found").foregroundStyle(.secondary) } }
            Divider()
            HStack {
                Spacer()
                Button("Load") { ScenarioSession.relaunch(into: selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLoad)
            }
            .padding(12)
        }
        .frame(minWidth: 400, minHeight: 280)
    }
}

/// The Scenarios menu, which only the scenarios bundle shows.
struct ScenarioCommands: Commands {
    var body: some Commands {
        if let session = ScenarioSession.active {
            CommandMenu("Scenarios") {
                ForEach(ScenarioSession.listings()) { listing in
                    Toggle(listing.title, isOn: Binding(get: { listing.folder.standardizedFileURL.path == session.scenario?.folder.standardizedFileURL.path },
                                                        set: { _ in ScenarioSession.relaunch(into: listing.name) }))
                        .disabled(listing.error != nil)
                }
                Divider()
                Button("Reload") { ScenarioSession.relaunch(into: session.selection) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(session.selection == nil)
                Button("Next Step") { session.nextStep() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("Show Picker") { session.showPicker() }
                Button("Reveal in Finder") { session.revealInFinder() }
            }
        }
    }
}
#endif
