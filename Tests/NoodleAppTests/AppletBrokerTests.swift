import AppletBridge
import NoodleCore
import NoodleRuntime
import XCTest

@testable import Noodle

@MainActor final class AppletBrokerTests: XCTestCase {
    func testForeignConversationLinksNeverReachTheCompanion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: repository, connection: { await recorder.respond($0) })
        let foreign: AppletBuildIdentity = AppletBuildIdentity.current == .production ? .development : .production
        let url = NoodletLink.url(for: UUID(), build: foreign)
        do { _ = try await controller.openNoodlet(url); XCTFail("Foreign link opened") }
        catch { XCTAssertEqual((error as? AppletError)?.code, "environment-mismatch") }
        do { _ = try await controller.resolvePreview(url); XCTFail("Foreign preview requested") }
        catch { XCTAssertEqual((error as? AppletError)?.code, "environment-mismatch") }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func token(for agent: AgentRecord, repository: WorkspaceRepository) throws -> String {
        let workspace = repository.directory(for: agent)
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: ".noodle/applet-bridge")
        return try JSONDecoder().decode(AppletAgentSession.self,
            from: mailbox.read("session.json", limit: 4096)).token
    }

    func testRestartedSessionRejectsPreviouslyQueuedRequestButAcceptsCurrentToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let agent = try repository.createAgent(named: "Session boundary").agent
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: repository, connection: { await recorder.respond($0) })
        controller.start(agents: [agent])
        defer { controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
        let previous = try token(for: agent, repository: repository)
        controller.start(agents: [])
        controller.start(agents: [agent])
        let current = try token(for: agent, repository: repository)
        XCTAssertNotEqual(current, previous)
        do {
            _ = try await controller.perform(.init(token: previous, request: .init(.list)), agent: agent)
            XCTFail("A queued request from the revoked session reached Applet")
        } catch {}
        _ = try await controller.perform(.init(token: current, request: .init(.list)), agent: agent)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSharedResultIsWithheldWhenConversationAccessIsRevokedInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let author = try repository.createAgent(named: "Author").agent
        let reader = try repository.createAgent(named: "Reader").agent
        let group = try repository.createGroup(named: "Shared", participantIDs: [author.id, reader.id], existingAgents: [author, reader])
        let id = UUID()
        let attachment = try repository.importLinkAttachment(NoodletLink.url(for: id), into: group.id)
        _ = try repository.sendAgentMessage(agentID: author.id, conversationID: group.id, body: "Shared", attachmentIDs: [attachment.id])
        let received = expectation(description: "Authorized request reached Applet")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let controller = AppletController(repository: repository, connection: { _ in
            received.fulfill()
            for await _ in release { break }
            var response = AppletResponse()
            response.text = "private shared result"
            return response
        })
        controller.start(agents: [reader])
        defer { continuation.finish(); controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
        var request = AppletRequest(.info); request.noodletID = id
        let envelope = AppletAgentEnvelope(token: try token(for: reader, repository: repository), request: request, conversationID: group.id)
        let pending = Task { try await controller.perform(envelope, agent: reader) }
        await fulfillment(of: [received], timeout: 3)
        _ = try repository.updateGroupParticipants(conversationID: group.id, participantIDs: [author.id], existingAgents: [author, reader])
        continuation.yield(); continuation.finish()
        do { _ = try await pending.value; XCTFail("Revoked participant received the shared result") } catch {}
    }

    func testSessionRevocationWithholdsSuccessAndErrorPayloadsInFlight() async throws {
        for (error, throwsError) in [(nil, false), ("Compiler diagnostics", false), ("Private diagnostics", true)] as [(String?, Bool)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let repository = WorkspaceRepository(rootURL: root)
            try repository.prepare()
            let agent = try repository.createAgent(named: "In flight").agent
            let received = expectation(description: "Request reached Applet")
            let (release, continuation) = AsyncStream<Void>.makeStream()
            let controller = AppletController(repository: repository, connection: { _ in
                received.fulfill()
                for await _ in release { break }
                if throwsError { throw AppletError(error!) }
                var response = AppletResponse(error: error)
                response.text = "private result"
                return response
            })
            controller.start(agents: [agent])
            defer { continuation.finish(); controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
            let envelope = AppletAgentEnvelope(token: try token(for: agent, repository: repository), request: .init(.list))
            let pending = Task { try await controller.perform(envelope, agent: agent) }
            await fulfillment(of: [received], timeout: 3)
            controller.start(agents: [])
            controller.start(agents: [agent])
            continuation.yield(); continuation.finish()
            do { _ = try await pending.value; XCTFail("A restarted session received a revoked session's payload") }
            catch { XCTAssertEqual(error.localizedDescription, "This Applet session is no longer active.") }
        }
    }

    func testAttachmentPreviewOnlyRequestsMetadataWithoutOpeningTheNoodlet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Preview.noodlet")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("noodlet.json"))
        let id = UUID()
        var response = AppletResponse()
        response.noodletID = id
        response.title = "Preview"
        response.previewBookmark = try package.bookmarkData()
        let previewResponse = response
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: WorkspaceRepository(rootURL: root), connection: {
            _ = await recorder.respond($0)
            return previewResponse
        })
        let preview = try await controller.resolvePreview(NoodletLink.url(for: id))
        XCTAssertEqual(preview.title, "Preview")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.operation, .info)
        XCTAssertEqual(requests.first?.noodletID, id)
        XCTAssertEqual(requests.first?.includePreview, true)
        XCTAssertNil(requests.first?.mode)
    }

    func testAttachmentOpenRequestsTheLiveForegroundRuntimeAndReportsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: repository, connection: { await recorder.respond($0) })
        let id = UUID()
        _ = try await controller.openNoodlet(NoodletLink.url(for: id))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.operation, .open)
        XCTAssertEqual(requests.first?.mode, "foreground")
        XCTAssertEqual(requests.first?.noodletID, id)
        XCTAssertNil(requests.first?.includePreview)
        XCTAssertNil(requests.first?.path)
        do { _ = try await controller.openNoodlet(URL(string: "https://example.com")!); XCTFail("Web URL reached Applet") } catch {}
        let failed = AppletController(repository: repository, connection: { _ in AppletResponse(error: "This noodlet is no longer available.") })
        do { _ = try await failed.openNoodlet(NoodletLink.url(for: id)); XCTFail("Missing package appeared to open") }
        catch { XCTAssertEqual(error.localizedDescription, "This noodlet is no longer available.") }
    }
    /// Showing a noodlet to people is the app's; sharing one names the bot that shared it, which a
    /// Noodle Hub uses to decide who may open it.
    func testBotsCannotShowNoodletsToPeopleAndSharingNamesTheBot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Author").agent
        let group = try repository.createGroup(named: "Shared", participantIDs: [bot.id], existingAgents: [bot])
        let id = UUID()
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: repository, connection: { request in
            _ = await recorder.respond(request)
            var response = AppletResponse()
            if request.operation == .present { response.url = NoodletLink.url(for: id); response.title = "Game" }
            return response
        })
        var shared: [(UUID, UUID, UUID)] = []
        controller.onShared = { shared.append(($0, $1, $2)) }
        controller.start(agents: [bot])
        defer { controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
        func invoke(_ request: AppletRequest, in conversation: UUID? = nil) async throws -> AppletResponse {
            try await controller.perform(AppletAgentEnvelope(token: try token(for: bot, repository: repository), request: request,
                                                             conversationID: conversation), agent: bot)
        }
        for operation in [AppletOperation.surfaceFrame, .surfaceInput] {
            var request = AppletRequest(operation, sessionID: UUID())
            request.surfaceInput = .text("x")
            do { _ = try await invoke(request); XCTFail("A bot used \(operation.rawValue)") } catch {}
        }
        let before = await recorder.requests
        XCTAssertEqual(before.count, 0)
        _ = try await invoke(AppletRequest(.present, sessionID: UUID()), in: group.id)
        XCTAssertEqual(shared.map(\.0), [id])
        XCTAssertEqual(shared.map(\.1), [bot.id])
        XCTAssertEqual(shared.map(\.2), [group.id])
    }

    func testOnlySentLinksGrantParticipantsSharedAccessAndNeverExposeBookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let a = try repository.createAgent(named: "Author").agent
        let b = try repository.createAgent(named: "Participant").agent
        let outsider = try repository.createAgent(named: "Outsider").agent
        let group = try repository.createGroup(named: "Shared", participantIDs: [a.id, b.id], existingAgents: [a, b])
        let id = UUID(), artifact = UUID()
        let recorder = AppletRequestRecorder()
        let controller = AppletController(repository: repository, connection: { request in
            _ = await recorder.respond(request)
            var response = AppletResponse()
            if request.operation == .screenshot { response.artifactID = artifact }
            return response
        })
        controller.start(agents: [a, b, outsider])
        defer { controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
        let attachment = try repository.importLinkAttachment(NoodletLink.url(for: id), into: group.id)
        var info = AppletRequest(.info)
        info.noodletID = id; info.includePreview = true; info.owner = "local"
        func invoke(_ request: AppletRequest, _ agent: AgentRecord = b) async throws -> AppletResponse {
            try await controller.perform(AppletAgentEnvelope(token: try token(for: agent, repository: repository), request: request, conversationID: group.id), agent: agent)
        }
        do { _ = try await invoke(info); XCTFail("An unsent draft granted access") } catch {}
        _ = try repository.sendAgentMessage(agentID: a.id, conversationID: group.id, body: "Try this", attachmentIDs: [attachment.id])
        _ = try await invoke(info)
        let sent = await recorder.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.owner, "local")
        XCTAssertNil(sent.first?.includePreview)
        do { _ = try await invoke(info, outsider); XCTFail("Outsider gained access") } catch {}
        info.path = "/tmp/other.noodlet"
        do { _ = try await invoke(info); XCTFail("Mixed target gained access") } catch {}
        info.path = nil; info.noodletID = UUID()
        do { _ = try await invoke(info); XCTFail("Unshared ID gained access") } catch {}
        var capture = AppletRequest(.screenshot); capture.noodletID = id
        _ = try await invoke(capture)
        var download = AppletRequest(.artifact); download.artifactID = artifact
        _ = try await invoke(download)
        do { _ = try await invoke(download, a); XCTFail("Another participant read an ungranted capture") } catch {}
        var exact = AppletRequest(.status, sessionID: UUID()); exact.noodletID = id
        _ = try await invoke(exact)
        let targeted = await recorder.requests.last
        XCTAssertEqual(targeted?.sessionID, exact.sessionID)
        XCTAssertEqual(targeted?.noodletID, id)
        XCTAssertEqual(targeted?.owner, "local")
        exact.noodletID = nil
        do { _ = try await invoke(exact); XCTFail("A session UUID alone granted shared access") } catch {}
        exact.noodletID = id
        do { _ = try await invoke(exact, outsider); XCTFail("Outsider targeted shared session") } catch {}
        let wrongGroup = try repository.createGroup(named: "Unshared", participantIDs: [a.id, b.id], existingAgents: [a, b])
        do {
            _ = try await controller.perform(AppletAgentEnvelope(token: try token(for: b, repository: repository), request: exact, conversationID: wrongGroup.id), agent: b)
            XCTFail("Wrong conversation granted session access")
        } catch {}
        _ = try repository.updateGroupParticipants(conversationID: group.id, participantIDs: [a.id], existingAgents: [a, b])
        do { _ = try await invoke(exact); XCTFail("Removed participant retained session access") } catch {}
    }

    func testPresentAttachesLiveWeblocInsteadOfPackageOrScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let a = try repository.createAgent(named: "Author")
        let id = UUID()
        let controller = AppletController(repository: repository, connection: { _ in
            var response = AppletResponse()
            response.noodletID = id; response.url = NoodletLink.url(for: id); response.title = "Hello"
            return response
        })
        controller.start(agents: [a.agent])
        defer { controller.start(agents: []); try? FileManager.default.removeItem(at: root) }
        _ = try await controller.perform(AppletAgentEnvelope(token: try token(for: a.agent, repository: repository), request: AppletRequest(.present, sessionID: UUID()),
            conversationID: a.conversation.id), agent: a.agent)
        let attachments = try repository.loadAttachments(conversationID: a.conversation.id)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.url, NoodletLink.url(for: id))
        XCTAssertEqual(attachments.first?.mediaType, "application/x-webloc")
        XCTAssertEqual(try repository.loadMessages(conversationID: a.conversation.id).last?.attachments, attachments.map(\.id))
    }
    func testCompanionInstallAndRemovalRefreshEveryHarnessWithoutRestart() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let application = root.appendingPathComponent("Noodle Applet.app")
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("repository"),
            launcherExecutableURL: root.appendingPathComponent("messenger"),
            discoverAppletApplication: { application })
        try repository.prepare()
        let helper = root.appendingPathComponent("noodlet")
        try Data("fixture".utf8).write(to: helper)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let agents = try HarnessProvider.allCases.map {
            try repository.createAgent(named: $0.rawValue, harnessIdentifier: $0.rawValue).agent
        }
        let controller = AppletController(repository: repository)
        controller.start(agents: agents)
        defer { controller.start(agents: []) }
        for agent in agents {
            let workspace = repository.directory(for: agent)
            XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet").path))
            // Exercise native Claude discovery directories as well as shared skills.
            let claudeSkills = workspace.appendingPathComponent(".claude/skills")
            try manager.removeItem(at: claudeSkills)
            try manager.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
            try Data("custom".utf8).write(to: claudeSkills.appendingPathComponent("custom.md"))
        }

        let executable = application.appendingPathComponent("Contents/MacOS/NoodleApplet")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": AppletConnection.providerID,
            "CFBundleExecutable": "NoodleApplet"], format: .xml, options: 0)
            .write(to: application.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        controller.refreshSkills()
        let laterAgent = try repository.createAgent(named: "New arrival").agent
        controller.start(agents: agents + [laterAgent])

        for agent in agents + [laterAgent] {
            let workspace = repository.directory(for: agent)
            XCTAssertTrue(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet/SKILL.md").path))
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent(".agents/skills/applet/noodlet").path), helper.path)
            XCTAssertTrue(try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("## Creative applets"))
        }

        // Preserve the fixture for a reinstall at the same canonical location.
        let backup = root.appendingPathComponent("removed.app")
        try manager.moveItem(at: application, to: backup)
        controller.refreshSkills()
        for agent in agents + [laterAgent] {
            let workspace = repository.directory(for: agent)
            XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet").path))
            XCTAssertNil(try? manager.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent(".claude/skills/applet").path))
            XCTAssertFalse(try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("## Creative applets"))
        }
        for agent in agents {
            XCTAssertEqual(try String(contentsOf: repository.directory(for: agent).appendingPathComponent(".claude/skills/custom.md"), encoding: .utf8), "custom")
        }
        try manager.moveItem(at: backup, to: application)
        controller.refreshSkills()
        for agent in agents + [laterAgent] {
            XCTAssertTrue(manager.fileExists(atPath: repository.directory(for: agent).appendingPathComponent(".claude/skills/applet/SKILL.md").path))
        }
        XCTAssertNil(controller.failure)
    }

    func testBrokerStampsIdentityAndRejectsRemovedAgents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let a = try repository.createAgent(named: "Applet A").agent
        let b = try repository.createAgent(named: "Applet B").agent
        let recorder = AppletRequestRecorder()
        let controller = AppletController(
            repository: repository, connection: { await recorder.respond($0) })
        controller.start(agents: [a, b])
        defer {
            controller.start(agents: [])
            try? FileManager.default.removeItem(at: root)
        }
        var request = AppletRequest(.list)
        request.owner = b.id.uuidString
        _ = try await controller.perform(
            AppletAgentEnvelope(token: try token(for: a, repository: repository), request: request), agent: a)
        let sent = await recorder.requests
        XCTAssertEqual(sent.first?.owner, a.id.uuidString.lowercased())
        controller.start(agents: [b])
        do {
            _ = try await controller.perform(
                AppletAgentEnvelope(token: try token(for: a, repository: repository), request: request), agent: a)
            XCTFail("Removed agent retained access")
        } catch {}
        let finalCount = await recorder.requests.count
        XCTAssertEqual(finalCount, 1)
    }
    func testBuildFailuresKeepSessionForDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let agent = try repository.createAgent(named: "Builder").agent
        let id = UUID()
        let controller = AppletController(
            repository: repository,
            connection: { _ in
                var response = AppletResponse(error: "Compiler error")
                response.sessionID = id
                return response
            })
        controller.start(agents: [agent])
        defer {
            controller.start(agents: [])
            try? FileManager.default.removeItem(at: root)
        }
        let response = try await controller.perform(
            AppletAgentEnvelope(token: try token(for: agent, repository: repository), request: AppletRequest(.build)), agent: agent)
        XCTAssertEqual(response.sessionID, id)
        XCTAssertEqual(response.error, "Compiler error")
    }
}
private actor AppletRequestRecorder {
    var requests: [AppletRequest] = []
    func respond(_ request: AppletRequest) -> AppletResponse {
        requests.append(request)
        return AppletResponse()
    }
}
