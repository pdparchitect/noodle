#if NOODLE_DEV_HOOKS
import Foundation
import NoodleCore
import NoodleScenarios

struct ScenarioLaunch {
    let folder: URL
    let selection: UUID?
    private let temporaryDirectory: URL
    private let scenario: Scenario
    private let seeded: Scenario.Seeded
    private let replay: Bool
    var replaysTimeline: Bool { replay }

    static func load() throws -> Self? {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.first == "--scenario" else { return nil }
        let replay = arguments.count == 3 && arguments.last == "--replay"
        guard arguments.count == 2 || replay,
              let name = arguments.dropFirst().first,
              !name.isEmpty, name != ".", name != "..",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw ScenarioError("Usage: NoodleWindows --scenario NAME [--replay]")
        }
        let files = FileManager.default
        let root = ProcessInfo.processInfo.environment["NOODLE_SCENARIOS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: files.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Scenarios", isDirectory: true)
        let scenario = try Scenario.load(from: root.appendingPathComponent(name, isDirectory: true),
                                         preferenceKeys: nil, settingsTabs: nil)
        let temporary = files.temporaryDirectory.appendingPathComponent("NoodleScenario-\(UUID())", isDirectory: true)
        let folder = temporary.appendingPathComponent("Workspace", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let repository = WorkspaceRepository(rootURL: folder)
            var seeded = Scenario.Seeded(clock: try ScenarioTime.start(scenario.clock, now: Date()),
                                        discovery: HarnessDiscovery(homeDirectory: temporary,
                                                                    executableSearchDirectories: [], environment: [:]))
            try scenario.seedStore(into: repository, seeded: &seeded)
            try scenario.applyOverlay(to: repository)
            let selection = scenario.present?.select.flatMap { seeded.conversations[$0]?.id ?? seeded.directs[$0]?.id }
            return Self(folder: folder, selection: selection, temporaryDirectory: temporary,
                        scenario: scenario, seeded: seeded, replay: replay)
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    @MainActor func play(in window: MainWindow) async throws {
        if let draft = scenario.present?.draft, let selection {
            window.setScenarioDraft(draft, for: selection)
        }
        guard replay else { return }
        let repository = WorkspaceRepository(rootURL: folder)
        let started = Date()
        for step in scenario.timeline ?? [] {
            if let wait = step.wait, wait > 0 {
                try await Task.sleep(for: .seconds(wait))
            }
            let now = seeded.clock.addingTimeInterval(Date().timeIntervalSince(started))
            let agent = step.agent.flatMap { seeded.agents[$0] }
            let conversation = step.in.flatMap { seeded.conversations[$0] } ?? step.agent.flatMap { seeded.directs[$0] }
            if let reply = step.reply, let agent, let conversation {
                let attachments = try scenario.importAttachments(reply.attachments, into: conversation.id, repository: repository, now: now)
                _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id, body: reply.text,
                                                   attachmentIDs: attachments, now: now)
                window.refreshScenario()
            }
            if let say = step.say, let conversation {
                let attachments = try scenario.importAttachments(say.attachments, into: conversation.id, repository: repository, now: now)
                _ = try repository.sendUserMessage(conversationID: conversation.id, body: say.text,
                                                  attachmentIDs: attachments, now: now)
                window.refreshScenario()
            }
            if let typing = step.type, let conversation {
                var draft = ""
                for character in typing.text {
                    draft.append(character)
                    window.setScenarioDraft(draft, for: conversation.id)
                    try await Task.sleep(for: .seconds(typing.interval ?? 0.075))
                }
                try await Task.sleep(for: .milliseconds(550))
                let date = seeded.clock.addingTimeInterval(Date().timeIntervalSince(started))
                let attachments = try scenario.importAttachments(typing.attachments, into: conversation.id, repository: repository, now: date)
                _ = try repository.sendUserMessage(conversationID: conversation.id, body: typing.text,
                                                  attachmentIDs: attachments, now: date)
                window.setScenarioDraft("", for: conversation.id)
                window.refreshScenario()
            }
            if let key = step.present?.select, let id = seeded.conversations[key]?.id {
                if let draft = step.present?.draft {
                    window.setScenarioDraft(draft, for: id)
                }
                window.refreshScenario(selecting: id)
            }
        }
    }

    func removeWorkspace() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
#endif
