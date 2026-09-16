import AppKit
import AppletBridge
import Foundation
import NoodleCore
import Observation

/// Bot-bound filesystem mailbox. The signed Noodle process owns caller identity;
/// CLI arguments never choose another bot's sessions or artifacts.
@MainActor @Observable final class AppletController {
    private(set) var failure: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var claimed: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: [UUID: Int] = [:]
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private let mailboxMonitor = WorkspaceMailboxMonitor()
    @ObservationIgnored private var launching: Task<Void, Error>?
    @ObservationIgnored private var sharedArtifacts: [UUID: (agent: UUID, conversation: UUID, owner: String, created: Date)] = [:]
    @ObservationIgnored private var skillExecutableURL: URL?
    @ObservationIgnored private var synchronizedSkills: Set<UUID> = []
    @ObservationIgnored private var lastSkillRefresh = Date.distantPast
    @ObservationIgnored private let connection:
        (@Sendable (AppletRequest) async throws -> AppletResponse)?
    init(
        repository: WorkspaceRepository,
        connection: (@Sendable (AppletRequest) async throws -> AppletResponse)? = nil
    ) {
        self.repository = repository
        self.connection = connection
    }
    func start(agents: [AgentRecord]) {
        mailboxMonitor.reset()
        self.agents = agents
        tokens = tokens.filter { id, _ in agents.contains { $0.id == id } }
        do {
            for agent in agents where tokens[agent.id] == nil {
                let directory = try AppletAgentSkill.bridge(
                    workspace: repository.directory(for: agent))
                let token = UUID().uuidString + UUID().uuidString
                try MCPBridgeFiles.write(
                    AppletAgentSession(token: token, processID: getpid()),
                    to: directory.appendingPathComponent("session.json"), workspace: repository.directory(for: agent))
                tokens[agent.id] = token
            }
        } catch { failure = error.localizedDescription }
        refreshSkills()
        if monitor == nil {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    self?.scan()
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
    }
    /// Every bot gets the managed integration while the companion is installed.
    /// Refresh without restarting harnesses or interrupting their current work.
    func refreshSkills() {
        lastSkillRefresh = Date()
        let executable = repository.appletExecutableURL
        if executable != skillExecutableURL {
            skillExecutableURL = executable
            synchronizedSkills.removeAll()
        }
        synchronizedSkills.formIntersection(agents.map(\.id))
        for agent in agents where !synchronizedSkills.contains(agent.id) {
            do {
                try repository.synchronizeAgentWorkspace(agent)
                synchronizedSkills.insert(agent.id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
    func openLibrary() async throws {
        guard
            let url = AppletApplication.locate()
        else { throw AppletError("Build or install \(AppletBuildIdentity.current.appName) first.") }
        _ = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func resolvePreview(_ url: URL) async throws -> NoodletPreviewAccess {
        let id = try NoodletLink.requireID(in: url)
        var request = AppletRequest(.info)
        request.noodletID = id
        request.includePreview = true
        let response = try await call(request).checked()
        return try NoodletPreviewAccess(response: response, expectedID: id)
    }
    @discardableResult
    func openNoodlet(_ url: URL) async throws -> AppletResponse {
        let id = try NoodletLink.requireID(in: url)
        var request = AppletRequest(.open)
        request.noodletID = id
        request.mode = "foreground"
        try Task.checkCancellation()
        return try await call(request).checked()
    }
    private func call(_ request: AppletRequest, authorize: () throws -> Void = {}) async throws -> AppletResponse {
        try authorize()
        if let connection { return try await connection(request) }
        let socket = try AppletConnection.socketURL()
        let team = try AppletConnection.signingTeam()
        do { return try await AppletConnection.call(request, socket: socket, team: team) } catch let
            error as AppletError where error.unavailable
        {
            if let launching {
                try await launching.value
            } else {
                let task = Task { @MainActor in
                    guard
                        let url = AppletApplication.locate()
                    else {
                        throw AppletError(
                            "Install \(AppletBuildIdentity.current.appName) to run noodlets. See Noodle Settings → Companion Apps."
                        )
                    }
                    try await AppletLaunch.openInBackground(at: url)
                }
                launching = task
                do {
                    try await task.value
                    launching = nil
                } catch {
                    launching = nil
                    throw error
                }
            }
            for _ in 0..<40 {
                // Companion startup and retries suspend this actor. Access may
                // have changed since the request was read from the mailbox.
                try authorize()
                do {
                    return try await AppletConnection.call(request, socket: socket, team: team)
                } catch let error as AppletError where error.unavailable {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw AppletError("Noodle Applet did not become ready.")
        }
    }
    private func scan() {
        if Date().timeIntervalSince(lastSkillRefresh) >= 5 { refreshSkills() }
        guard mailboxMonitor.hasChanges() else { return }
        sharedArtifacts = sharedArtifacts.filter { Date().timeIntervalSince($0.value.created) < 3600 }
        claimed = claimed.filter { Date().timeIntervalSince($0.value) < 300 }
        for agent in agents {
            guard (inFlight[agent.id] ?? 0) < 3, let token = tokens[agent.id],
                mailboxMonitor.needsScan(workspace: repository.directory(for: agent), path: ".noodle/applet-bridge"),
                let directory = try? AppletAgentSkill.bridge(
                    workspace: repository.directory(for: agent)),
                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for file in files.prefix(512) where file.pathExtension == "request" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                    claimed[id] == nil
                else { continue }
                claimed[id] = Date()
                let output = directory.appendingPathComponent(
                    id.uuidString.lowercased() + ".response")
                do {
                    let envelope = try JSONDecoder().decode(
                        AppletAgentEnvelope.self,
                        from: MCPBridgeFiles.read(file, limit: AppletConnection.maxFrame, workspace: repository.directory(for: agent)))
                    guard envelope.id == id, envelope.request.id == id, envelope.token == token,
                        envelope.expiresAt > Date(),
                        envelope.expiresAt.timeIntervalSinceNow
                            <= Double(envelope.request.operation.timeout + 5)
                    else { throw AppletError("Invalid or expired Applet session.") }
                    try envelope.request.validate()
                    inFlight[agent.id, default: 0] += 1
                    Task { [weak self] in
                        guard let self else { return }
                        defer { self.inFlight[agent.id, default: 1] -= 1 }
                        let response: AppletResponse
                        do { response = try await self.perform(envelope, agent: agent) } catch {
                            response = AppletResponse(error: error.localizedDescription,
                                errorCode: (error as? AppletError)?.code)
                        }
                        try? MCPBridgeFiles.write(response, to: output, workspace: self.repository.directory(for: agent))
                    }
                    break
                } catch {
                    try? MCPBridgeFiles.write(
                        AppletResponse(error: error.localizedDescription), to: output, workspace: repository.directory(for: agent))
                }
            }
        }
    }
    func perform(_ envelope: AppletAgentEnvelope, agent: AgentRecord) async throws -> AppletResponse
    {
        func checkAccess() throws {
            guard agents.contains(where: { $0.id == agent.id }), tokens[agent.id] == envelope.token else {
                throw AppletError("This Applet session is no longer active.")
            }
            if let conversation = envelope.conversationID {
                do { _ = try repository.participantRoster(for: agent.id, conversationID: conversation) }
                catch { throw AppletError(error.localizedDescription, code: "session-unavailable") }
            }
        }
        try checkAccess()
        var request = envelope.request
        request.includePreview = nil
        request.owner = agent.id.uuidString.lowercased()
        try request.validate()
        if let conversation = envelope.conversationID {
            if request.operation == .artifact {
                guard let id = request.artifactID, let grant = sharedArtifacts[id],
                      grant.agent == agent.id, grant.conversation == conversation,
                      Date().timeIntervalSince(grant.created) < 3600 else {
                    throw AppletError("This capture is unavailable to the conversation.")
                }
                request.owner = grant.owner
            } else if request.operation != .present {
                guard let id = request.noodletID, request.files == nil,
                      ![.build, .validate, .list, .artifact].contains(request.operation) else {
                    throw AppletError("Use --id with a shared noodlet link and --conversation; add --session to target its exact session.", code: "session-unavailable")
                }
                let messages = try repository.loadMessages(conversationID: conversation)
                let sent = Set(messages.flatMap(\.attachments))
                guard try repository.loadAttachments(conversationID: conversation).contains(where: {
                    sent.contains($0.id) && $0.url.flatMap(NoodletLink.build) == .current && $0.url.flatMap(NoodletLink.id) == id
                }) else { throw AppletError("This noodlet has not been shared with the conversation.", code: "session-unavailable") }
                // The signed broker authorizes the specific shared package, with any explicit session constrained to that package by Applet.
                request.owner = "local"
            }
        }
        if request.operation == .present, envelope.conversationID == nil {
            throw AppletError("Specify --conversation to share a preview.")
        }
        var response: AppletResponse
        do { response = try await call(request, authorize: checkAccess) }
        catch {
            try checkAccess()
            throw error
        }
        // Even error responses can carry logs or artifacts. Recheck before
        // returning any payload or granting access to a shared capture.
        try checkAccess()
        response.previewBookmark = nil
        if response.error != nil { return response }
        if let conversation = envelope.conversationID, let artifact = response.artifactID {
            sharedArtifacts[artifact] = (agent.id, conversation, request.owner!, Date())
        }
        if request.operation == .present, let conversation = envelope.conversationID {
            guard let url = response.url, (try? NoodletLink.requireID(in: url)) != nil else {
                throw AppletError("Update Noodle Applet to share noodlet links.")
            }
            _ = try repository.participantRoster(for: agent.id, conversationID: conversation)
            let attachment = try repository.importLinkAttachment(url, into: conversation)
            do {
                _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation,
                    body: response.title ?? response.text ?? "Noodlet", attachmentIDs: [attachment.id])
            } catch {
                try? repository.removeAttachment(attachment)
                throw error
            }
        }
        return response
    }
    deinit { monitor?.cancel() }
}
