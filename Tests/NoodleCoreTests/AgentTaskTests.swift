import XCTest
@testable import NoodleCore

final class AgentTaskTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func messenger(_ agent: AgentRecord, _ arguments: String...) -> MessengerCommandResult {
        let command = repository.directory(for: agent).appendingPathComponent(".agents/skills/messenger/messenger")
        return MessengerCLI.runDirect(arguments: [command.path] + arguments)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from result: MessengerCommandResult) throws -> Value {
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(result.standardOutput.utf8))
    }

    func testBotAddsMovesAndListsItsOwnTasks() throws {
        let created = try repository.createAgent(named: "Alfred"); let bot = created.agent, direct = created.conversation
        let task = try decode(AgentTask.self, from: messenger(bot, "--add-task", "Find offsite venue", "--conversation", direct.id.uuidString))
        XCTAssertEqual(task.title, "Find offsite venue")
        XCTAssertEqual(task.state, .open)
        XCTAssertEqual(task.conversationID, direct.id)

        let waiting = try decode(AgentTask.self, from: messenger(bot, "--update-task", task.id.uuidString,
            "--state", "waiting", "--on", "user", "--note", "Pick one of three venues"))
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertEqual(waiting.waitingOn, .user)
        XCTAssertEqual(waiting.note, "Pick one of three venues")

        // Leaving waiting forgets who it waited on.
        let done = try decode(AgentTask.self, from: messenger(bot, "--update-task", task.id.uuidString, "--state", "done"))
        XCTAssertEqual(done.state, .done)
        XCTAssertNil(done.waitingOn)

        let list = try decode(AgentTaskList.self, from: messenger(bot, "--list-tasks"))
        XCTAssertEqual(list.mine.map(\.id), [task.id])
        XCTAssertTrue(list.waitingOnMe.isEmpty)
        XCTAssertEqual(try repository.loadTasks(agentID: bot.id).map(\.state), [.done])
    }

    /// A note too long is refused with how long it was and how to shorten it, so a bot writes less rather
    /// than squeezing the spaces out of what it has.
    func testATooLongNoteSaysHowToShortenIt() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        let task = try decode(AgentTask.self, from: messenger(bot, "--add-task", "Tidy the notes"))
        let refused = messenger(bot, "--update-task", task.id.uuidString, "--note", String(repeating: "word ", count: 70))
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertEqual(refused.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
            "messenger: This note is 349 characters; a task note is at most 300. Say where the task stands in a sentence or two of plain words, and keep details in a file or the conversation.")
    }

    func testTaskWithoutThreadIsAllowed() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        let task = try decode(AgentTask.self, from: messenger(bot, "--add-task", "Tidy the notes"))
        XCTAssertNil(task.conversationID)
    }

    func testOnlyTheOwnerChangesATaskAndOthersSeeWhatWaitsOnThem() throws {
        let alfred = try repository.createAgent(named: "Alfred").agent
        let oscar = try repository.createAgent(named: "Oscar").agent
        let group = try repository.createGroup(named: "Offsite", participantIDs: [alfred.id, oscar.id],
                                               existingAgents: [alfred, oscar])
        let task = try decode(AgentTask.self, from: messenger(alfred, "--add-task", "Book the venue", "--conversation", group.id.uuidString))
        _ = try decode(AgentTask.self, from: messenger(alfred, "--update-task", task.id.uuidString,
            "--state", "waiting", "--on", oscar.id.uuidString, "--note", "Budget sign-off"))

        let oscars = try decode(AgentTaskList.self, from: messenger(oscar, "--list-tasks"))
        XCTAssertTrue(oscars.mine.isEmpty)
        XCTAssertEqual(oscars.waitingOnMe.map(\.task.id), [task.id])
        XCTAssertEqual(oscars.waitingOnMe.first?.ownerID, alfred.id)

        XCTAssertNotEqual(messenger(oscar, "--update-task", task.id.uuidString, "--state", "done").exitCode, 0)
        XCTAssertEqual(try repository.loadTasks(agentID: alfred.id).first?.state, .waiting)
    }

    func testWaitingOnSomeoneOutsideTheThreadIsRefused() throws {
        let alfred = try repository.createAgent(named: "Alfred")
        let oscar = try repository.createAgent(named: "Oscar").agent
        let task = try decode(AgentTask.self, from: messenger(alfred.agent, "--add-task", "Venue", "--conversation", alfred.conversation.id.uuidString))
        XCTAssertNotEqual(messenger(alfred.agent, "--update-task", task.id.uuidString, "--state", "waiting", "--on", oscar.id.uuidString).exitCode, 0)
        XCTAssertNotEqual(messenger(alfred.agent, "--update-task", task.id.uuidString, "--state", "waiting", "--on", alfred.agent.id.uuidString).exitCode, 0)
        XCTAssertNotEqual(messenger(alfred.agent, "--update-task", task.id.uuidString, "--on", "user").exitCode, 0,
                          "--on goes with waiting.")
    }

    func testTaskInAConversationTheBotIsNotInIsRefused() throws {
        let alfred = try repository.createAgent(named: "Alfred").agent
        let oscar = try repository.createAgent(named: "Oscar")
        XCTAssertNotEqual(messenger(alfred, "--add-task", "Snoop", "--conversation", oscar.conversation.id.uuidString).exitCode, 0)
    }

    func testOpenTasksAreCapped() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        for index in 0..<AgentTaskLimits.open { _ = try repository.addTask(agentID: bot.id, title: "Task \(index)") }
        XCTAssertThrowsError(try repository.addTask(agentID: bot.id, title: "One too many"))
        let first = try XCTUnwrap(repository.loadTasks(agentID: bot.id).first)
        _ = try repository.updateTask(agentID: bot.id, id: first.id, state: .dropped)
        XCTAssertNoThrow(try repository.addTask(agentID: bot.id, title: "Room again"))
    }

    func testFinishedTasksAreClearedAfterAWeekAndOpenOnesStay() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let done = try repository.addTask(agentID: bot.id, title: "Done", now: start)
        _ = try repository.updateTask(agentID: bot.id, id: done.id, state: .done, now: start)
        let open = try repository.addTask(agentID: bot.id, title: "Still open", now: start)

        XCTAssertEqual(try repository.listTasks(agentID: bot.id, now: start.addingTimeInterval(6 * 86_400)).mine.count, 2)
        let later = try repository.listTasks(agentID: bot.id, now: start.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(later.mine.map(\.id), [open.id])
    }

    func testTasksOfADeletedThreadAreCleared() throws {
        let alfred = try repository.createAgent(named: "Alfred").agent
        let oscar = try repository.createAgent(named: "Oscar").agent
        let group = try repository.createGroup(named: "Offsite", participantIDs: [alfred.id, oscar.id], existingAgents: [alfred, oscar])
        _ = try repository.addTask(agentID: alfred.id, title: "Venue", conversationID: group.id)
        try repository.deleteConversation(id: group.id)
        XCTAssertTrue(try repository.listTasks(agentID: alfred.id).mine.isEmpty)
    }

    func testFeedbackOnATaskReachesTheBotWithTheTask() throws {
        let created = try repository.createAgent(named: "Alfred"); let bot = created.agent, direct = created.conversation
        let task = try repository.addTask(agentID: bot.id, title: "Find offsite venue", conversationID: direct.id)
        _ = try repository.sendUserMessage(conversationID: direct.id, body: "The second one, under 2k",
                                           task: TaskReference(task, agentID: bot.id))
        let deliveries = try decode([MessengerDelivery].self, from: messenger(bot, "--get-latest"))
        XCTAssertEqual(deliveries.last?.message.task, TaskReference(id: task.id, agentID: bot.id, title: "Find offsite venue"))
    }
}
