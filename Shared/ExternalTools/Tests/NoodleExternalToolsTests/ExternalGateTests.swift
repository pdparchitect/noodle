import Foundation
@testable import NoodleExternalTools
import Testing

@MainActor private final class Prompts: ExternalPrompting {
    var approve = true
    var pick: UUID?
    var confirm = true
    var asked: [String] = []
    func approve(_ launcher: ExternalLauncher) async -> Bool { asked.append("approve \(launcher.name)"); return approve }
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? {
        asked.append("pick " + items.map(\.name).joined(separator: ",")); return pick
    }
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool { asked.append("confirm " + action); return confirm }
}

/// Answers yes, but only after a moment, as a person would.
@MainActor private final class SlowPrompts: ExternalPrompting {
    var approvals = 0, questions = 0
    func approve(_ launcher: ExternalLauncher) async -> Bool {
        approvals += 1; try? await Task.sleep(for: .milliseconds(100)); return true
    }
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? {
        questions += 1; try? await Task.sleep(for: .milliseconds(100)); return items.first?.id
    }
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool {
        questions += 1; try? await Task.sleep(for: .milliseconds(100)); return true
    }
}

private let claude = ExternalLauncher(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", name: "Claude Code", path: "/c")
private let codex = ExternalLauncher(key: "team:2DC432GLL2:com.openai.codex", name: "Codex", path: "/x")

@MainActor @Suite struct ExternalGateTests {
    private func gate(_ prompts: Prompts, enabled: Bool = true) -> ExternalGate {
        let gate = ExternalGate(url: nil, prompter: prompts)
        gate.enabled = enabled
        return gate
    }

    @Test func nothingIsServedWhileTurnedOff() async {
        let prompts = Prompts()
        await #expect(throws: ExternalToolsError.self) { try await gate(prompts, enabled: false).admit(claude) }
        #expect(prompts.asked.isEmpty)
    }

    @Test func aNewCallerIsAskedForOnceThenRemembered() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let first = try await gate.admit(claude)
        let again = try await gate.admit(claude)
        #expect(first.id == again.id)
        #expect(prompts.asked == ["approve Claude Code"])
        #expect(gate.grants.callers.count == 1)
    }

    @Test func aRefusedCallerIsNotAskedAboutAgainStraightAway() async {
        let prompts = Prompts(); prompts.approve = false
        let gate = gate(prompts)
        await #expect(throws: ExternalToolsError.self) { try await gate.admit(claude) }
        await #expect(throws: ExternalToolsError.self) { try await gate.admit(claude) }
        #expect(prompts.asked == ["approve Claude Code"])
        #expect(gate.grants.callers.isEmpty)
    }

    @Test func callersSeeOnlyWhatTheyMadeOrWereLent() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let mine = UUID(), lent = UUID(), other = UUID()
        let caller = try await gate.admit(claude)
        gate.recordCreated(mine, by: caller.id)
        prompts.pick = lent
        let picked = try await gate.borrow(for: caller.id, from: [ExternalItem(id: lent, name: "Shopping"), ExternalItem(id: other, name: "Bank")])
        #expect(picked == lent)
        #expect(gate.allows(caller.id, mine) && gate.allows(caller.id, lent))
        #expect(!gate.allows(caller.id, other))
        #expect(throws: ExternalToolsError.self) { try gate.require(caller.id, other) }
        #expect(gate.created(caller.id, mine) && !gate.created(caller.id, lent))

        let second = try await gate.admit(codex)
        #expect(!gate.allows(second.id, mine))
    }

    @Test func borrowingOffersOnlyWhatTheCallerCannotAlreadyUse() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let mine = UUID(), other = UUID()
        let caller = try await gate.admit(claude)
        gate.recordCreated(mine, by: caller.id)
        await #expect(throws: ExternalToolsError.self) { try await gate.borrow(for: caller.id, from: []) }
        prompts.pick = nil
        await #expect(throws: ExternalToolsError.self) {
            try await gate.borrow(for: caller.id, from: [ExternalItem(id: mine, name: "Mine"), ExternalItem(id: other, name: "Other")])
        }
        #expect(prompts.asked.last == "pick Other")
        #expect(!gate.allows(caller.id, other))
    }

    @Test func aDeclinedConfirmationFails() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let caller = try await gate.admit(claude)
        prompts.confirm = false
        await #expect(throws: ExternalToolsError.self) { try await gate.confirm(for: caller.id, message: "Make it?", action: "Create") }
    }

    @Test func switchesInSettingsGrantAndRevoke() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let caller = try await gate.admit(claude), item = UUID()
        gate.setAccess(true, to: item, for: caller.id)
        #expect(gate.allows(caller.id, item) && !gate.created(caller.id, item))
        gate.setAccess(false, to: item, for: caller.id)
        #expect(!gate.allows(caller.id, item))
    }

    @Test func removedCallersAndDeletedItemsAreForgotten() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let caller = try await gate.admit(claude), item = UUID(), gone = UUID()
        gate.recordCreated(item, by: caller.id); gate.recordCreated(gone, by: caller.id)
        gate.forget(gone)
        #expect(!gate.allows(caller.id, gone))
        gate.prune(keeping: [])
        #expect(!gate.allows(caller.id, item))
        let removed = gate.remove(caller.id)
        #expect(removed?.id == caller.id)
        #expect(gate.grants.callers.isEmpty)
        _ = try await gate.admit(claude)
        #expect(prompts.asked == ["approve Claude Code", "approve Claude Code"])
    }

    @Test func callsArrivingTogetherShareOneQuestion() async throws {
        let prompts = SlowPrompts(), gate = ExternalGate(url: nil, prompter: prompts)
        gate.enabled = true
        async let first = gate.admit(claude)
        async let second = gate.admit(claude)
        let (a, b) = try await (first, second)
        #expect(a.id == b.id)
        #expect(prompts.approvals == 1)
        #expect(gate.grants.callers.count == 1)
    }

    @Test func aCallerCannotStackQuestions() async throws {
        let prompts = SlowPrompts(), gate = ExternalGate(url: nil, prompter: prompts)
        gate.enabled = true
        let caller = try await gate.admit(claude)
        async let open = gate.confirm(for: caller.id, message: "Make one?", action: "Create")
        // The first question is still open: the second fails at once instead of piling up.
        await Task.yield()
        await #expect(throws: ExternalToolsError.self) { try await gate.borrow(for: caller.id, from: [ExternalItem(id: UUID(), name: "A")]) }
        try await open
        #expect(prompts.questions == 1)
    }

    @Test func aDeclinedQuestionIsNotAskedAgainStraightAway() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        let caller = try await gate.admit(claude)
        prompts.confirm = false; prompts.pick = nil
        let items = [ExternalItem(id: UUID(), name: "A")]
        await #expect(throws: ExternalToolsError.self) { try await gate.confirm(for: caller.id, message: "Make one?", action: "Create") }
        await #expect(throws: ExternalToolsError.self) { try await gate.confirm(for: caller.id, message: "Make one?", action: "Create") }
        await #expect(throws: ExternalToolsError.self) { try await gate.borrow(for: caller.id, from: items) }
        await #expect(throws: ExternalToolsError.self) { try await gate.borrow(for: caller.id, from: items) }
        #expect(prompts.asked == ["approve Claude Code", "confirm Create", "pick A"])
    }

    @Test func losingAccessIsReportedSoSessionsCanClose() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        var revoked: [[UUID]] = []
        gate.revoked = { _, ids in revoked.append(ids) }
        let caller = try await gate.admit(claude), lent = UUID(), made = UUID()
        gate.setAccess(true, to: lent, for: caller.id)
        gate.recordCreated(made, by: caller.id)
        gate.setAccess(false, to: lent, for: caller.id)
        gate.setAccess(false, to: lent, for: caller.id)
        #expect(revoked == [[lent]])
        gate.remove(caller.id)
        #expect(revoked == [[lent], [made]])
    }

    @Test func turningExternalToolsOffEndsEveryCallersSessions() async throws {
        let prompts = Prompts(), gate = gate(prompts)
        var revoked: [UUID: [UUID]] = [:]
        gate.revoked = { caller, ids in revoked[caller, default: []] += ids }
        let first = try await gate.admit(claude), second = try await gate.admit(codex), a = UUID(), b = UUID()
        gate.recordCreated(a, by: first.id)
        gate.setAccess(true, to: b, for: second.id)
        gate.enabled = false
        #expect(revoked == [first.id: [a], second.id: [b]])
        // What they may use is kept for when external tools are turned on again.
        #expect(gate.allows(first.id, a) && gate.allows(second.id, b))
    }

    @Test func aFailedSaveChangesNothing() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        // The settings file would go inside a plain file, which cannot hold it.
        let gate = ExternalGate(url: blocker.appendingPathComponent("external-tools.json"), prompter: Prompts())
        gate.enabled = true
        #expect(!gate.enabled)
        #expect(gate.failure != nil)
        await #expect(throws: ExternalToolsError.self) { try await gate.admit(claude) }
    }

    @Test func grantsSurviveARestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prompts = Prompts(), item = UUID()
        let first = ExternalGate(url: url, prompter: prompts)
        first.enabled = true
        let caller = try await first.admit(claude)
        first.recordCreated(item, by: caller.id)
        let second = ExternalGate(url: url, prompter: prompts)
        #expect(second.enabled)
        #expect(second.allows(caller.id, item) && second.created(caller.id, item))
    }

    @Test func anUnreadableFileTurnsExternalToolsOffAndIsLeftAlone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let gate = ExternalGate(url: url, prompter: Prompts())
        #expect(!gate.enabled)
        gate.enabled = true
        #expect(!gate.enabled)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}
