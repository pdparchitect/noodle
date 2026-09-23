#if NOODLE_DEV_HOOKS
import Foundation
import NoodleCore
import NoodleLaunchChecks
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// Scenarios are loaded by path from `Scenarios/` at the repository root. Every folder there is
/// loaded, seeded and played here, so a scenario that no longer fits the app fails before a capture run does.
@MainActor final class ScenarioTests: XCTestCase {
    private static let scenariosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scenarios", isDirectory: true)
    private var directories: [URL] = []
    private var suites: [String] = []
    private var sessions: [ScenarioSession] = []

    override func tearDown() async throws {
        for session in sessions { session.store.stopMonitoring() }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-scenario-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func session(_ scenario: Scenario) throws -> ScenarioSession {
        let suite = "Noodle.ScenarioTests.\(UUID())"
        suites.append(suite)
        let session = try ScenarioSession(scenario, root: try directory(), defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        session.sleep = { _ in await Task.yield() }
        sessions.append(session)
        return session
    }

    /// Two bots, one of them stopped at its usage limit, and a short history with the first.
    private func fixture(timeline: String = "[]", extra: String = "", botExtra: String = "", in folder: URL? = nil) throws -> URL {
        let folder = try folder ?? directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        { "version": 1, "title": "Fixture", "clock": "09:41", \(extra)
          "harnesses": { "claude-code": { "models": "builtin" },
                         "grok-build": { "models": [ { "id": "grok-code", "name": "Grok Code", "efforts": ["low", "high"], "defaultEffort": "high", "default": true } ] } },
          "agents": [ { "key": "ada", "name": "Ada", "harness": "claude-code", "model": "opus", "effort": "high", "autoReplies": ["On it."] \(botExtra) },
                      { "key": "rex", "name": "Rex", "harness": "grok-build", "model": "grok-code",
                        "status": { "phase": "failed", "detail": "Usage limit reached", "failure": "usageLimit" } } ],
          "conversations": [ { "key": "ada", "direct": "ada", "messages": [
              { "key": "ask", "at": "-1d 17:05", "from": "user", "text": "Can you look at the parser change?" },
              { "at": "09:30", "from": "ada", "text": "Yes. Two small things, both in the tokenizer." } ] },
            { "key": "rex", "direct": "rex" } ],
          "timeline": \(timeline) }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("scenario.json"))
        return folder
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting until \(what)")
    }

    /// The scenario, or nothing when it is only waiting for scripts/scenario.sh to fetch media.
    private func loaded(_ folder: URL) throws -> Scenario? {
        do { return try Scenario.load(from: folder) } catch let error as ScenarioError
            where error.needsFetch { return nil }
    }

    func testEveryScenarioFolderLoadsSeedsAndPlays() async throws {
        // A folder is a scenario when it holds one. The others beside them, the shared
        // cast and the cache of what has been fetched, are not.
        let folders = try FileManager.default.contentsOfDirectory(at: Self.scenariosRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scenario.json").path) }
        XCTAssertFalse(folders.isEmpty, "Scenarios/ holds no scenarios")

        for folder in folders {
            let name = folder.lastPathComponent
            // Media named by web address is only in the ignored cache scripts/scenario.sh fills,
            // so a fresh checkout plays the scenarios that do not wait on it.
            guard let scenario = try loaded(folder) else { continue }
            let session = try session(scenario)
            let store = try XCTUnwrap(session.store), seeded = session.seeded
            XCTAssertTrue(store.storageReady, name)
            XCTAssertNil(store.errorMessage, name)

            XCTAssertEqual(store.agents.count, scenario.agents.count, name)
            for entry in scenario.agents {
                let agent = try XCTUnwrap(store.agents.first { $0.id == seeded.agents[entry.key]?.id }, "\(name): \(entry.key)")
                XCTAssertEqual(agent.displayName, entry.name, name)
                XCTAssertEqual(agent.harnessIdentifier, entry.harness, name)
                XCTAssertEqual(agent.modelIdentifier, entry.model, name)
                XCTAssertEqual(agent.avatarImageData != nil, entry.avatar?.image != nil, "\(name): \(entry.key)")
                // The sandboxed app cannot ask whether a file in its container is executable, which is how a
                // harness of the user's own is found. One that Noodle installed is found without asking.
                let installation = try XCTUnwrap(store.runtime.installation(for: agent), "\(name): \(entry.harness) should look installed")
                XCTAssertTrue(ManagedHarnessStore(root: store.repository.rootURL.deletingLastPathComponent().appendingPathComponent("Home")).manages(installation), "\(name): \(entry.harness)")
            }

            let entries = scenario.conversations ?? []
            XCTAssertEqual(store.conversations.count, scenario.agents.count + entries.filter { $0.group != nil }.count, name)
            for entry in entries {
                let conversation = try XCTUnwrap(store.conversations.first { $0.id == seeded.conversations[entry.key]?.id }, "\(name): \(entry.key)")
                let messages = store.messages(for: conversation)
                XCTAssertEqual(messages.count, entry.messages?.count ?? 0, "\(name): \(entry.key)")
                for (message, expected) in zip(messages, entry.messages ?? []) {
                    XCTAssertEqual(message.author, expected.from == "user" ? .user : .agent(try XCTUnwrap(seeded.agents[expected.from]).id), "\(name): \(expected.at)")
                    XCTAssertEqual(message.body, expected.text, name)
                    XCTAssertEqual(message.delivery, expected.delivery ?? .delivered, "\(name): \(expected.at)")
                    XCTAssertEqual(message.attachments.count, expected.attachments?.count ?? 0, "\(name): \(expected.at)")
                    for attachment in store.attachments(for: message) {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentFileURL(attachment).path), "\(name): \(attachment.originalFilename)")
                    }
                    XCTAssertEqual(store.attachments(for: message).count, message.attachments.count, "\(name): \(expected.at)")
                    XCTAssertEqual(message.reactions?.map(\.emoji) ?? [], expected.reactions?.map(\.emoji) ?? [], "\(name): \(expected.at)")
                }
                XCTAssertEqual(conversation.updatedAt, messages.last?.createdAt ?? conversation.updatedAt, "\(name): \(entry.key) sorts by its last message")
                let background = store.background(for: conversation)
                XCTAssertEqual(background.preset, entry.background?.preset, "\(name): \(entry.key)")
                let media = entry.background?.image ?? entry.background?.video
                XCTAssertEqual(background.imageFilename != nil, media != nil, "\(name): \(entry.key)")
                XCTAssertEqual(background.mediaKind == .video, entry.background?.video != nil, "\(name): \(entry.key) keeps what it was given")
                if background.imageFilename != nil {
                    let url = try XCTUnwrap(store.repository.backgroundImageURL(background, conversationID: conversation.id))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name): \(entry.key)")
                }
                XCTAssertEqual(store.hasUnreadMessages(in: conversation), entry.unread == true, "\(name): \(entry.key)")
            }
            if let selected = scenario.present?.select {
                XCTAssertEqual(store.selectedConversationID, seeded.conversations[selected]?.id, name)
            }
            if let draft = scenario.present?.draft { XCTAssertEqual(store.draft, draft, name) }
            XCTAssertEqual(store.pendingAttachments.count, scenario.present?.draftAttachments?.count ?? 0, name)

            store.startAgents()
            for entry in scenario.agents {
                let agent = try XCTUnwrap(seeded.agents[entry.key])
                let snapshot = store.runtime.snapshot(for: agent.id)
                XCTAssertEqual(snapshot.phase, entry.status?.phase ?? .ready, "\(name): \(entry.key)")
                if let detail = entry.status?.detail { XCTAssertEqual(snapshot.detail, detail, "\(name): \(entry.key)") }
                XCTAssertEqual(snapshot.failure != nil, entry.status?.failure != nil, "\(name): \(entry.key)")
                XCTAssertEqual(store.runtime.models(for: entry.harness).map(\.id), scenario.models(for: try XCTUnwrap(HarnessProvider(rawValue: entry.harness))).map(\.id), name)
            }

            // Play the whole timeline: no delays, and the owner's part is played for them.
            var typed = 0, shots: [String] = []
            session.pause = { pause in
                switch pause {
                case .key: break
                case .shot(let shot): shots.append(shot)
                case .userMessage(let bot):
                    guard let conversation = seeded.directs[bot] else { return false }
                    store.setDraft("Go ahead.", for: conversation.id)
                    store.sendDraft(to: conversation.id)
                    typed += 1
                }
                return true
            }
            try await session.play()

            let timeline = scenario.timeline ?? []
            XCTAssertEqual(shots, timeline.compactMap(\.capture), name)
            XCTAssertEqual(typed, timeline.filter { $0.waitFor == .userMessage }.count, name)
            let seededMessages = entries.reduce(0) { $0 + ($1.messages?.count ?? 0) }
            let sent = timeline.filter { $0.reply != nil || $0.say != nil || $0.type != nil }.count
            let expected = seededMessages + sent + typed
            let saved = try store.conversations.reduce(0) { $0 + (try store.repository.loadMessages(conversationID: $1.id).count) }
            XCTAssertEqual(saved, expected, "\(name): messages after the timeline")
            XCTAssertEqual(store.messagesByConversation.values.reduce(0) { $0 + $1.count }, expected, "\(name): the store shows what was saved")
            for entry in scenario.agents {
                guard let last = timeline.last(where: { $0.agent == entry.key && $0.status != nil })?.status else { continue }
                XCTAssertEqual(store.runtime.snapshot(for: try XCTUnwrap(seeded.agents[entry.key]).id).phase, last.phase, "\(name): \(entry.key) after the timeline")
            }
            XCTAssertEqual(store.errorMessage, timeline.last { $0.error != nil }?.error, name)
        }
    }

    /// Media a scenario names by web address lives in an ignored cache that only
    /// scripts/scenario.sh fills, so a fresh checkout has none of it. That is a scenario waiting
    /// to be fetched, not a broken one, and it has to be told apart from a real mistake.
    func testAScenarioWaitingToBeFetchedIsNotABrokenOne() throws {
        let folder = try fixture(extra: "\"film\": { \"background\": \"https://example.com/video/1/\" },")
        XCTAssertThrowsError(try Scenario.load(from: folder)) {
            XCTAssertTrue(try! XCTUnwrap($0 as? ScenarioError).needsFetch, $0.localizedDescription)
        }
        let listing = try XCTUnwrap(
            ScenarioSession.listings(in: folder.deletingLastPathComponent())
                .first { $0.folder == folder.standardizedFileURL })
        XCTAssertTrue(listing.needsFetch)
        XCTAssertEqual(listing.title, "Fixture")

        // A genuine mistake stays a plain error.
        XCTAssertThrowsError(try Scenario.load(from: try fixture(extra: "\"clok\": \"10:00\","))) {
            XCTAssertFalse(try! XCTUnwrap($0 as? ScenarioError).needsFetch, $0.localizedDescription)
        }
    }

    func testUnknownKeysAndMissingAssetsFail() throws {
        XCTAssertEqual(try Scenario.load(from: try fixture()).title, "Fixture")

        XCTAssertThrowsError(try Scenario.load(from: try fixture(extra: "\"clok\": \"10:00\","))) {
            XCTAssertTrue($0.localizedDescription.contains("clok"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(botExtra: ", \"avatar\": { \"symbl\": \"hammer.fill\" }"))) {
            XCTAssertTrue($0.localizedDescription.contains("agents[0].avatar.symbl"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(botExtra: ", \"avatar\": { \"image\": \"assets/nobody.png\" }"))) {
            XCTAssertTrue($0.localizedDescription.contains("assets/nobody.png"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(timeline: "[ { \"agent\": \"ada\", \"reply\": { \"text\": \"Done.\", \"attachments\": [ { \"file\": \"../outside.txt\" } ] } } ]"))) {
            XCTAssertTrue($0.localizedDescription.contains("outside.txt"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(timeline: "[ { \"agent\": \"grace\", \"status\": { \"phase\": \"ready\" } } ]"))) {
            XCTAssertTrue($0.localizedDescription.contains("grace"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(extra: "\"appearance\": \"light\",")))
    }

    func testSettingsKeysAreKnownPreferences() throws {
        let settings = "\"settings\": { \"chatAttachmentLayout\": \"stack\", \"Noodle.firstBotSetup.dismissed\": true },"
        let scenario = try Scenario.load(from: try fixture(extra: settings))
        let session = try session(scenario)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(suites.last)))
        XCTAssertEqual(defaults.string(forKey: ChatAttachmentLayout.defaultsKey), ChatAttachmentLayout.stack.rawValue)
        XCTAssertTrue(defaults.bool(forKey: FirstBotSetup.dismissedKey))
        XCTAssertEqual(MessageDeliveryMode.load(from: defaults), .queue, "Scripted bots never wait for the on-device classifier")
        XCTAssertNil(session.store.errorMessage)

        XCTAssertThrowsError(try Scenario.load(from: try fixture(extra: "\"settings\": { \"chatAttachmentLayuot\": \"stack\" },"))) {
            XCTAssertTrue($0.localizedDescription.contains("chatAttachmentLayuot"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Scenario.load(from: try fixture(extra: "\"settings\": { \"messageDeliveryMode\": \"automatic\" },")))
    }

    func testSeededHistoryIsNotRedeliveredAtStart() async throws {
        let session = try session(try Scenario.load(from: try fixture()))
        let ada = try XCTUnwrap(session.seeded.agents["ada"])
        XCTAssertEqual(try session.repository.latestMessages(for: ada.id, consuming: false).count, 0)
        session.store.startAgents()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.process(for: "ada")?.notifications, 0)
        XCTAssertEqual(session.process(for: "rex")?.notifications, 0)

        // The same start does wake a bot for a message it has not read, and fetching it is what marks it delivered.
        let unread = try self.session(try Scenario.load(from: try fixture()))
        let conversation = try XCTUnwrap(unread.seeded.conversations["ada"])
        let message = try unread.repository.sendUserMessage(conversationID: conversation.id, body: "One more thing.")
        XCTAssertEqual(message.delivery, .queued)
        unread.store.startAgents()
        await waitUntil("the unread message wakes its bot") { unread.process(for: "ada")?.notifications == 1 }
        XCTAssertEqual(try unread.repository.loadMessages(conversationID: conversation.id).last?.delivery, .delivered)
    }

    func testFailedStatusOffersKickConfirmation() async throws {
        let session = try session(try Scenario.load(from: try fixture()))
        let rex = try XCTUnwrap(session.seeded.agents["rex"])
        session.store.startAgents()
        XCTAssertEqual(session.runtime.snapshot(for: rex.id).failure, .usageLimit)
        XCTAssertNil(session.runtime.kick(agent: try XCTUnwrap(session.seeded.agents["ada"]), repository: session.repository), "A ready bot has nothing to confirm")

        let request = try XCTUnwrap(session.runtime.kick(agent: rex, repository: session.repository))
        XCTAssertEqual(request.failure, .usageLimit)
        XCTAssertEqual(request.title, "Usage limit reached")
        XCTAssertEqual(session.runtime.snapshot(for: rex.id).phase, .failed, "Nothing restarts before the confirmation")

        session.runtime.confirmKick(request, repository: session.repository)
        await waitUntil("the kicked bot is ready") { session.runtime.snapshot(for: rex.id).phase == .ready }
        XCTAssertNil(session.runtime.snapshot(for: rex.id).failure)
    }

    func testAMessageToAStoppedBotStaysSent() async throws {
        let timeline = "[ { \"in\": \"rex\", \"say\": { \"text\": \"Are you there?\" } }, { \"in\": \"ada\", \"say\": { \"text\": \"Morning.\" } } ]"
        let session = try session(try Scenario.load(from: try fixture(timeline: timeline)))
        session.store.startAgents()
        try await session.play()
        let rex = try XCTUnwrap(session.seeded.conversations["rex"]), ada = try XCTUnwrap(session.seeded.conversations["ada"])
        XCTAssertEqual(try session.repository.loadMessages(conversationID: rex.id).last?.delivery, .queued)
        XCTAssertEqual(try session.repository.loadMessages(conversationID: ada.id).last?.delivery, .delivered)
        XCTAssertEqual(try session.repository.loadMessages(conversationID: ada.id).count, 3, "The timeline speaks for the bots until it ends")
    }

    func testATypeStepTypesIntoTheComposerAndThenSends() async throws {
        let timeline = """
        [ { "in": "ada", "type": { "key": "ship", "text": "Ship it.", "interval": 0.02 } },
          { "agent": "ada", "react": { "message": "ship", "emoji": "👍" } } ]
        """
        let session = try session(try Scenario.load(from: try fixture(timeline: timeline)))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        let store = try XCTUnwrap(session.store)
        var drafts: [String] = []
        session.sleep = { _ in drafts.append(store.draft(for: conversation.id)); await Task.yield() }
        store.startAgents()
        try await session.play()
        XCTAssertEqual(Array(drafts.prefix(3)), ["S", "Sh", "Shi"], "The draft grows a character at a time")
        XCTAssertEqual(drafts.last, "Ship it.", "The whole message is on screen before it is sent")
        let messages = try session.repository.loadMessages(conversationID: conversation.id)
        XCTAssertEqual(messages.last?.body, "Ship it.")
        XCTAssertEqual(messages.last?.delivery, .delivered)
        XCTAssertEqual(messages.last?.reactions?.map(\.emoji), ["👍"], "A later step can name the typed message")
        XCTAssertEqual(store.draft(for: conversation.id), "", "The composer is empty once the message is sent")
    }

    func testAutoRepliesAnswerOnceTheTimelineHasFinished() async throws {
        let session = try session(try Scenario.load(from: try fixture()))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        session.store.startAgents()
        try await session.play()
        session.store.setDraft("Ship it when the tests pass.", for: conversation.id)
        session.store.sendDraft(to: conversation.id)
        await waitUntil("Ada answers") { (try? session.repository.loadMessages(conversationID: conversation.id).last?.body) == "On it." }
        let messages = try session.repository.loadMessages(conversationID: conversation.id)
        XCTAssertEqual(messages.dropLast().last?.delivery, .delivered)
        XCTAssertEqual(session.runtime.snapshot(for: try XCTUnwrap(session.seeded.agents["ada"]).id).phase, .ready)
    }

    /// A scenario shows a file being put in the composer and then sent, the way someone would do
    /// it. What is in the composer has to go with the message and leave the composer empty, or the
    /// attachment is both sent and still sitting there.
    func testTypingSendsWhatIsAlreadyInTheComposerAndLeavesItEmpty() async throws {
        let folder = try directory()
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: folder.appendingPathComponent("assets/clip.mp4"))
        let timeline = """
            [ { "present": { "select": "ada", "draftAttachments": ["assets/clip.mp4"] } },
              { "in": "ada", "type": { "text": "Schedule this for tomorrow.", "interval": 0.001 } } ]
            """
        let scenario = try Scenario.load(
            from: try fixture(timeline: timeline, extra: "\"present\": { \"select\": \"ada\" },", in: folder))
        let session = try session(scenario)
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        session.store.startAgents()
        try await session.play()

        let sent = try XCTUnwrap(session.repository.loadMessages(conversationID: conversation.id).last)
        XCTAssertEqual(sent.body, "Schedule this for tomorrow.")
        XCTAssertEqual(sent.attachmentIDs?.count, 1, "The clip in the composer was not sent")
        XCTAssertTrue(
            session.store.pendingAttachments(for: conversation.id).isEmpty,
            "The clip is still sitting in the composer after it was sent")
        XCTAssertEqual(
            session.store.draft(for: conversation.id), "",
            "The typed message is still sitting in the composer after it was sent")
    }

    /// Nobody is meant to be at the keyboard during a capture run, but a stray key or click lands
    /// in the app and is recorded: a half-typed word in the composer, a menu open over the film.
    /// An automated run takes the keyboard and mouse away from whoever is passing by.
    @MainActor func testACaptureRunTakesTheKeyboardAndMouseAwayFromTheApp() throws {
        let session = try session(try Scenario.load(from: try fixture()))
        XCTAssertFalse(session.blocksInput, "An ordinary run is meant to be driven by hand")

        session.takesShots = true
        XCTAssertTrue(session.blocksInput)
        for type in [NSEvent.EventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel] {
            XCTAssertTrue(
                ScenarioSession.unwantedInput.contains(NSEvent.EventTypeMask(rawValue: 1 << UInt64(type.rawValue))),
                "\(type) still reaches the app while it is being filmed")
        }

        session.takesShots = false
        XCTAssertFalse(session.blocksInput, "The keyboard comes back when the run is not automated")
    }

    func testNextStepResumesATimelinePausedForAKey() async throws {
        let timeline = "[ { \"waitFor\": \"key\" }, { \"agent\": \"ada\", \"reply\": { \"text\": \"All 42 parser tests pass.\" } } ]"
        let session = try session(try Scenario.load(from: try fixture(timeline: timeline)))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        session.store.startAgents()
        let playing = Task { try await session.play() }
        await waitUntil("the timeline pauses") { session.isWaitingForKey }
        XCTAssertEqual(try session.repository.loadMessages(conversationID: conversation.id).count, 2)

        session.nextStep()
        try await playing.value
        XCTAssertFalse(session.isWaitingForKey)
        XCTAssertEqual(try session.repository.loadMessages(conversationID: conversation.id).last?.body, "All 42 parser tests pass.")
        session.nextStep()
    }

    func testACaptureRunSendsTheDraftAndDoesNotStopForAKey() async throws {
        let timeline = "[ { \"waitFor\": \"key\" }, { \"waitFor\": \"userMessage\", \"agent\": \"ada\" }, { \"agent\": \"ada\", \"reply\": { \"text\": \"Done.\" } } ]"
        let present = "\"present\": { \"select\": \"ada\", \"draft\": \"Ship it when the tests pass.\" },"
        let session = try session(try Scenario.load(from: try fixture(timeline: timeline, extra: present)))
        let conversation = try XCTUnwrap(session.seeded.conversations["ada"])
        session.takesShots = true
        session.store.startAgents()
        try await session.play()
        XCTAssertEqual(try session.repository.loadMessages(conversationID: conversation.id).suffix(2).map(\.body), ["Ship it when the tests pass.", "Done."])
        XCTAssertEqual(session.store.draft(for: conversation.id), "")
    }

    func testScenarioFlagDigest() {
        XCTAssertEqual(LaunchChecks.digest("--scenario"), DevelopmentHook.scenario)
        XCTAssertEqual(LaunchChecks.digest("--scenario-shots"), DevelopmentHook.scenarioShots)
        XCTAssertEqual(LaunchChecks.digest("--scenario-picker"), DevelopmentHook.scenarioPicker)
    }

    func testLaunchRefusesOutsideScenariosBundle() {
        XCTAssertTrue(ScenarioSession.isIsolated(bundleIdentifier: "com.pdparchitect.noodle.scenarios"))
        for identifier in ["com.pdparchitect.noodle", "com.pdparchitect.noodle.local", "com.pdparchitect.noodle.scenarios.share", nil] {
            XCTAssertFalse(ScenarioSession.isIsolated(bundleIdentifier: identifier), identifier ?? "nil")
        }
        // The test runner is not that bundle either: without the argument the app simply opens as usual.
        XCTAssertNil(ScenarioSession.launch(LaunchChecks(arguments: ["Noodle"])))
        XCTAssertNil(ScenarioSession.active)
    }

    func testTheChoiceMadeInTheAppIsKeptUntilItIsReplaced() throws {
        let pointer = try directory().appendingPathComponent("state/scenario-selection.txt")
        let none = LaunchChecks(arguments: ["Noodle"])
        XCTAssertNil(ScenarioSession.selection(none, pointer: pointer))

        try ScenarioSession.select("group-review", pointer: pointer)
        XCTAssertEqual(ScenarioSession.selection(none, pointer: pointer), "group-review")
        XCTAssertEqual(ScenarioSession.selection(none, pointer: pointer), "group-review", "Reading the choice keeps it, so Reload returns to it")
        try ScenarioSession.select("direct-chat", pointer: pointer)
        XCTAssertEqual(ScenarioSession.selection(none, pointer: pointer), "direct-chat")

        try ScenarioSession.select(nil, pointer: pointer)
        XCTAssertNil(ScenarioSession.selection(none, pointer: pointer))
        try Data(" \n".utf8).write(to: pointer)
        XCTAssertNil(ScenarioSession.selection(none, pointer: pointer))
    }

    func testTheLaunchArgumentBeatsTheChoiceMadeInTheApp() throws {
        let pointer = try directory().appendingPathComponent("scenario-selection.txt")
        try ScenarioSession.select("group-review", pointer: pointer)
        let checks = LaunchChecks(arguments: ["Noodle", "--scenario", "/tmp/Scenarios/direct-chat", "-AppleLocale", "en_US"])
        XCTAssertEqual(ScenarioSession.selection(checks, pointer: pointer), "/tmp/Scenarios/direct-chat")
        XCTAssertEqual(ScenarioSession.selection(LaunchChecks(arguments: ["Noodle", "--scenario"]), pointer: pointer), "group-review")
        XCTAssertNil(ScenarioSession.selection(LaunchChecks(arguments: ["Noodle", "--scenario-picker"]), pointer: pointer), "The script opens the picker whatever was shown last")
        XCTAssertEqual(ScenarioSession.selection(LaunchChecks(arguments: ["Noodle"]), pointer: pointer), "group-review", "Asking for the picker does not forget the choice")

        let root = URL(fileURLWithPath: "/tmp/Scenarios", isDirectory: true)
        XCTAssertEqual(ScenarioSession.folder(for: "direct-chat", root: root)?.path, "/tmp/Scenarios/direct-chat")
        XCTAssertEqual(ScenarioSession.folder(for: "/elsewhere/demo", root: root)?.path, "/elsewhere/demo")
        XCTAssertNil(ScenarioSession.folder(for: "direct-chat", root: nil))
    }

    /// Launch Services will not open a second instance of a sandboxed app, so the bundle reopens once this one is gone.
    func testTheBundleReopensOnlyAfterTheAppHasQuit() throws {
        let reopened = try directory().appendingPathComponent("reopened")
        let reopener = try ScenarioSession.reopener(of: reopened, with: "/usr/bin/touch")
        try reopener.process.run()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.path), "The app is still running")

        try reopener.whileRunning.close()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: reopened.path) { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.path))
    }

    func testListingsKeepAScenarioThatDoesNotLoadAndSayWhy() throws {
        let root = try directory()
        _ = try fixture(in: root.appendingPathComponent("good"))
        _ = try fixture(extra: "\"clok\": \"10:00\",", in: root.appendingPathComponent("broken"))
        try Data("{".utf8).write(to: try fixture(in: root.appendingPathComponent("unreadable")).appendingPathComponent("scenario.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)

        let listings = ScenarioSession.listings(in: root)
        XCTAssertEqual(listings.map(\.name), ["broken", "good", "unreadable"])
        XCTAssertEqual(listings.map(\.title), ["Fixture", "Fixture", "unreadable"])
        XCTAssertNil(listings[1].error)
        XCTAssertTrue(try XCTUnwrap(listings[0].error).contains("clok"))
        XCTAssertNotNil(listings[2].error)
        XCTAssertTrue(ScenarioSession.listings(in: nil).isEmpty)

        let shipped = ScenarioSession.listings(in: Self.scenariosRoot)
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.scenariosRoot.path)
            .filter { FileManager.default.fileExists(atPath: Self.scenariosRoot.appendingPathComponent("\($0)/scenario.json").path) }
        XCTAssertEqual(shipped.map(\.name), folders.sorted())
        for listing in shipped where !listing.needsFetch {
            XCTAssertNil(listing.error, listing.name)
        }
    }
}
#endif
