import AppletBridge
import NoodleCore
import XCTest

@testable import Noodle

@MainActor final class AppletBrokerTests: XCTestCase {
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
            try await controller.perform(AppletAgentEnvelope(token: "test", request: request, conversationID: group.id), agent: agent)
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
        _ = try await controller.perform(AppletAgentEnvelope(token: "test", request: AppletRequest(.present, sessionID: UUID()),
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
            XCTAssertFalse(try String(contentsOf: workspace.appendingPathComponent(".agents/managed-skills.json"), encoding: .utf8).contains("skills/applet"))
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
            AppletAgentEnvelope(token: "test", request: request), agent: a)
        let sent = await recorder.requests
        XCTAssertEqual(sent.first?.owner, a.id.uuidString.lowercased())
        controller.start(agents: [b])
        do {
            _ = try await controller.perform(
                AppletAgentEnvelope(token: "test", request: request), agent: a)
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
            AppletAgentEnvelope(token: "test", request: AppletRequest(.build)), agent: agent)
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
