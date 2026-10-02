import AppletBridge
import NoodleAppletTools
import NoodleCore
import XCTest

final class AppletToolProviderTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private let granted: ToolAssignments = [AppletToolGrant.kind: [AppletToolGrant.id]]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Calls a tool as `messenger tool applet` does: through the broker, with the app's own host services.
    private func call(_ tool: String, _ arguments: [String: Any], as agent: AgentRecord, provider: AppletToolProvider,
                      assignments: @escaping @Sendable () -> ToolAssignments? = { nil }) async throws -> [String: Any] {
        let registry = ToolProviderRegistry()
        try registry.register(provider)
        let granted = granted
        let request = ToolBridgeRequest(session: "", action: .call, provider: "applet", tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let result = try await ToolBroker.perform(request, registry: registry, assignments: { assignments() ?? granted },
            context: ToolCallContext(agentID: agent.id, workspace: repository.directory(for: agent)),
            host: .repository(repository) { _ in granted })
        return try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
    }

    private func package(_ name: String, in agent: AgentRecord) throws -> URL {
        let url = repository.directory(for: agent).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBotsGetEveryCommandButThoseForPeople() async throws {
        let provider = AppletToolProvider { _ in AppletResponse() }
        let list = try await provider.tools(context: ToolCallContext(agentID: UUID(), workspace: root))
        let names = try ToolDescriptor.list(mcp: list).map(\.name)
        XCTAssertEqual(names, AppletGuidance.toolOperations.map(\.rawValue))
        for hidden in [AppletOperation.surfaceStream, .archive, .store, .show, .artifact] {
            XCTAssertFalse(names.contains(hidden.rawValue), hidden.rawValue)
        }
        XCTAssertTrue(names.contains("present"))
        XCTAssertEqual(provider.manifest.activation, .whenGranted(AppletToolGrant.kind, id: AppletToolGrant.id))
    }

    /// Without the grant Noodle gives while Noodle Applet is installed, there is no applet tool.
    func testTheToolNeedsItsGrant() async throws {
        let agent = try repository.createAgent(named: "Kai").agent
        let recorder = Recorder()
        let provider = AppletToolProvider { await recorder.respond($0) }
        do {
            _ = try await call("list", [:], as: agent, provider: provider, assignments: { ToolAssignments.none })
            XCTFail("The tool ran without its grant")
        } catch {}
        let sent = await recorder.requests
        XCTAssertTrue(sent.isEmpty)
    }

    /// A bot builds and opens noodlets from its own folder only, which is what makes a noodlet
    /// that bot's wherever it is linked; another bot's folder, or one outside, is refused.
    func testABotOpensNoodletsFromItsOwnFolderOnly() async throws {
        let kai = try repository.createAgent(named: "Kai").agent, eli = try repository.createAgent(named: "Eli").agent
        let own = try package("Counter.noodlet", in: kai)
        let other = try package("Counter.noodlet", in: eli)
        try FileManager.default.createSymbolicLink(at: repository.directory(for: kai).appendingPathComponent("Linked.noodlet"),
                                                   withDestinationURL: other)
        let recorder = Recorder()
        let provider = AppletToolProvider { await recorder.respond($0) }
        let opened = try await call("open", ["path": "Counter.noodlet"], as: kai, provider: provider)
        XCTAssertEqual(opened["isError"] as? Bool, false)
        for elsewhere in [other.path, "../\(eli.id.uuidString)/Counter.noodlet", "/tmp/Counter.noodlet", "Linked.noodlet", "Missing.noodlet"] {
            do {
                let result = try await call("open", ["path": elsewhere], as: kai, provider: provider)
                XCTAssertEqual(result["isError"] as? Bool, true, elsewhere)
            } catch {}
        }
        let sent = await recorder.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.path, canonical(own))
        // The bot is the one the broker identified, whatever the arguments say.
        XCTAssertEqual(sent.first?.owner, kai.id.uuidString.lowercased())
        XCTAssertEqual(sent.first?.mode, nil)
    }

    /// A noodlet window reaches the screen only when a person opens it; a bot keeps its work out of sight.
    func testBotsCannotBringNoodletsToTheForeground() async throws {
        let bot = try repository.createAgent(named: "Author").agent
        _ = try package("Counter.noodlet", in: bot)
        let recorder = Recorder()
        let provider = AppletToolProvider { await recorder.respond($0) }
        for (tool, arguments) in [("open", ["path": "Counter.noodlet", "mode": "foreground"]),
                                  ("restart", ["session": UUID().uuidString, "mode": "foreground"])] {
            let result = try await call(tool, arguments, as: bot, provider: provider)
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
        }
        do { _ = try await call("show", ["session": UUID().uuidString], as: bot, provider: provider); XCTFail("show is a tool") } catch {}
        _ = try await call("open", ["path": "Counter.noodlet", "mode": "background"], as: bot, provider: provider)
        let sent = await recorder.requests
        XCTAssertEqual(sent.map(\.mode), ["background"])
    }

    /// Only a link someone sent in the conversation reaches a shared noodlet, only for its
    /// participants, and never with a way into the package.
    func testOnlySentLinksGrantParticipantsSharedAccess() async throws {
        let a = try repository.createAgent(named: "Author").agent
        let b = try repository.createAgent(named: "Participant").agent
        let outsider = try repository.createAgent(named: "Outsider").agent
        let group = try repository.createGroup(named: "Shared", participantIDs: [a.id, b.id], existingAgents: [a, b])
        let id = UUID(), link = NoodletLink.url(for: id).absoluteString
        let recorder = Recorder()
        let provider = AppletToolProvider { await recorder.respond($0) }
        let shared: [String: Any] = ["link": link, "conversation": group.id.uuidString]
        let attachment = try repository.importLinkAttachment(NoodletLink.url(for: id), into: group.id)
        do { _ = try await call("info", shared, as: b, provider: provider); XCTFail("An unsent draft granted access") } catch {}
        _ = try repository.sendAgentMessage(agentID: a.id, conversationID: group.id, body: "Try this", attachmentIDs: [attachment.id])
        _ = try await call("info", shared, as: b, provider: provider)
        var sent = await recorder.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.noodletID, id)
        XCTAssertEqual(sent.first?.owner, "local")
        XCTAssertNil(sent.first?.includePreview)
        do { _ = try await call("info", shared, as: outsider, provider: provider); XCTFail("Outsider gained access") } catch {}
        let unshared = ["link": NoodletLink.url(for: UUID()).absoluteString, "conversation": group.id.uuidString]
        do { _ = try await call("info", unshared, as: b, provider: provider); XCTFail("Unshared link gained access") } catch {}
        let wrongGroup = try repository.createGroup(named: "Unshared", participantIDs: [a.id, b.id], existingAgents: [a, b])
        do {
            _ = try await call("info", ["link": link, "conversation": wrongGroup.id.uuidString], as: b, provider: provider)
            XCTFail("Wrong conversation granted access")
        } catch {}
        // A conversation alone, or a link beside another target, never widens what the bot reaches.
        let alone = try await call("info", ["id": id.uuidString, "conversation": group.id.uuidString], as: b, provider: provider)
        XCTAssertEqual(alone["isError"] as? Bool, true)
        _ = try package("Other.noodlet", in: b)
        let mixed = try await call("info", shared.merging(["path": "Other.noodlet"]) { $1 }, as: b, provider: provider)
        XCTAssertEqual(mixed["isError"] as? Bool, true)
        let session = UUID()
        _ = try await call("status", shared.merging(["session": session.uuidString]) { $1 }, as: b, provider: provider)
        sent = await recorder.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.sessionID, session)
        XCTAssertEqual(sent.last?.noodletID, id)
        XCTAssertEqual(sent.last?.owner, "local")
        _ = try repository.updateGroupParticipants(conversationID: group.id, participantIDs: [a.id], existingAgents: [a, b])
        do { _ = try await call("status", shared, as: b, provider: provider); XCTFail("Removed participant kept access") } catch {}
    }

    func testSharedResultIsWithheldWhenTheParticipantIsRemovedInFlight() async throws {
        let author = try repository.createAgent(named: "Author").agent
        let reader = try repository.createAgent(named: "Reader").agent
        let group = try repository.createGroup(named: "Shared", participantIDs: [author.id, reader.id], existingAgents: [author, reader])
        let link = NoodletLink.url(for: UUID())
        let attachment = try repository.importLinkAttachment(link, into: group.id)
        _ = try repository.sendAgentMessage(agentID: author.id, conversationID: group.id, body: "Shared", attachmentIDs: [attachment.id])
        let received = expectation(description: "Authorized request reached Applet")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let provider = AppletToolProvider { _ in
            received.fulfill()
            for await _ in release { break }
            var response = AppletResponse()
            response.text = "private shared result"
            return response
        }
        let pending = Task { [self] in try await call("info", ["link": link.absoluteString, "conversation": group.id.uuidString], as: reader, provider: provider) }
        await fulfillment(of: [received], timeout: 3)
        _ = try repository.updateGroupParticipants(conversationID: group.id, participantIDs: [author.id], existingAgents: [author, reader])
        continuation.yield(); continuation.finish()
        do {
            let result = try await pending.value
            XCTFail("A removed participant received the shared result: \(result)")
        } catch {}
    }

    /// Sharing posts the live noodlet's link with its card, not its package or a screenshot.
    func testPresentAttachesTheLiveLink() async throws {
        let bot = try repository.createAgent(named: "Author")
        let id = UUID()
        let provider = AppletToolProvider { request in
            var response = AppletResponse()
            if request.operation == .present { response.noodletID = id; response.url = NoodletLink.url(for: id); response.title = "Hello" }
            return response
        }
        let result = try await call("present", ["session": UUID().uuidString, "conversation": bot.conversation.id.uuidString],
                                    as: bot.agent, provider: provider)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let attachments = try repository.loadAttachments(conversationID: bot.conversation.id)
        XCTAssertEqual(attachments.map(\.url), [NoodletLink.url(for: id)])
        XCTAssertEqual(attachments.first?.mediaType, "application/x-webloc")
        let message = try XCTUnwrap(repository.loadMessages(conversationID: bot.conversation.id).last)
        XCTAssertEqual(message.attachments, attachments.map(\.id))
        XCTAssertEqual(message.body, "Hello")
        let other = try repository.createAgent(named: "Elsewhere")
        do {
            _ = try await call("present", ["session": UUID().uuidString, "conversation": other.conversation.id.uuidString],
                               as: bot.agent, provider: provider)
            XCTFail("Shared into a conversation the bot is not in")
        } catch {}
    }

    /// A capture lands in a new workspace file in one call, read back in pieces as the bot's.
    func testScreenshotSavesTheCaptureToANewFile() async throws {
        let bot = try repository.createAgent(named: "Author").agent
        let artifact = UUID(), session = UUID()
        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        let recorder = Recorder()
        let provider = AppletToolProvider { request in
            _ = await recorder.respond(request)
            var response = AppletResponse()
            response.sessionID = session
            if request.operation == .screenshot { response.artifactID = artifact }
            if request.operation == .artifact {
                let start = request.offset ?? 0, end = min(start + 128, bytes.count)
                response.data = bytes.subdata(in: start..<end); response.offset = end; response.done = end == bytes.count
            }
            return response
        }
        let result = try await call("screenshot", ["session": session.uuidString, "output": "shot.png"], as: bot, provider: provider)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: repository.directory(for: bot).appendingPathComponent("shot.png")), bytes)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertNil(structured["artifactID"])
        XCTAssertEqual(structured["output"] as? String, "shot.png")
        let sent = await recorder.requests
        XCTAssertEqual(sent.map(\.operation), [.screenshot, .artifact, .artifact, .artifact])
        XCTAssertTrue(sent.allSatisfy { $0.owner == bot.id.uuidString.lowercased() })
        do {
            _ = try await call("screenshot", ["session": session.uuidString, "output": "shot.png"], as: bot, provider: provider)
            XCTFail("An existing file was replaced")
        } catch {}
    }

    func testEvalReadsItsScriptFromAWorkspaceFile() async throws {
        let bot = try repository.createAgent(named: "Author").agent
        try Data("return 1 + 1;".utf8).write(to: repository.directory(for: bot).appendingPathComponent("check.js"))
        let recorder = Recorder()
        let provider = AppletToolProvider { await recorder.respond($0) }
        _ = try await call("eval", ["session": UUID().uuidString, "file": "check.js"], as: bot, provider: provider)
        let sent = await recorder.requests
        XCTAssertEqual(sent.first?.text, "return 1 + 1;")
    }

    /// A failed build keeps its session and error code, so the bot can read its logs.
    func testFailuresKeepTheirSessionForDiagnostics() async throws {
        let bot = try repository.createAgent(named: "Builder").agent
        _ = try package("Broken.noodlet", in: bot)
        let session = UUID()
        let provider = AppletToolProvider { _ in
            var response = AppletResponse(error: "Compiler error", errorCode: "session-not-running")
            response.sessionID = session
            return response
        }
        let result = try await call("build", ["path": "Broken.noodlet"], as: bot, provider: provider)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["error"] as? String, "Compiler error")
        XCTAssertEqual(structured["errorCode"] as? String, "session-not-running")
        XCTAssertEqual(structured["sessionID"] as? String, session.uuidString)
    }

    /// The skill a bot reads is the tool's own, generated like every other tool's.
    func testTheSkillCarriesTheAppletGuidance() async throws {
        let bot = try repository.createAgent(named: "Reader").agent
        let provider = AppletToolProvider { _ in AppletResponse() }
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: ToolCallContext(agentID: bot.id, workspace: root)))
        let workspace = repository.directory(for: bot)
        ToolProviderSkills.synchronize(workspace: workspace, providers: [(provider.manifest, tools)])
        let skill = try String(contentsOf: workspace.appendingPathComponent(".agents/skills/applet/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.contains("messenger tool applet"))
        XCTAssertTrue(skill.contains("--link URL --conversation UUID"))
        for operation in AppletGuidance.toolOperations {
            XCTAssertTrue(skill.contains("### \(operation.rawValue)\n"), operation.rawValue)
        }
        XCTAssertFalse(skill.contains("noodlet COMMAND"))
        XCTAssertFalse(skill.contains("./.agents/skills/applet/noodlet"))
    }
}

/// The path as the file system names it, which is how the broker hands a folder on.
private func canonical(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private actor Recorder {
    var requests: [AppletRequest] = []
    func respond(_ request: AppletRequest) -> AppletResponse {
        requests.append(request)
        return AppletResponse()
    }
}
