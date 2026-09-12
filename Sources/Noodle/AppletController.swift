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
        self.agents = agents
        tokens = tokens.filter { id, _ in agents.contains { $0.id == id } }
        do {
            for agent in agents where tokens[agent.id] == nil {
                let directory = try AppletAgentSkill.bridge(
                    workspace: repository.directory(for: agent))
                let token = UUID().uuidString + UUID().uuidString
                try MCPBridgeFiles.write(
                    AppletAgentSession(token: token, processID: getpid()),
                    to: directory.appendingPathComponent("session.json"))
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
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: AppletConnection.providerID)
        else { throw AppletError("Build or install Noodle Applet first.") }
        _ = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func resolvePreview(_ url: URL) async throws -> NoodletPreviewAccess {
        guard let id = NoodletLink.id(in: url) else { throw AppletError("Invalid noodlet link.") }
        var request = AppletRequest(.info)
        request.noodletID = id
        request.includePreview = true
        let response = try await call(request).checked()
        return try NoodletPreviewAccess(response: response, expectedID: id)
    }
    @discardableResult
    func openNoodlet(_ url: URL) async throws -> AppletResponse {
        guard let id = NoodletLink.id(in: url) else { throw AppletError("Invalid noodlet link.") }
        var request = AppletRequest(.open)
        request.noodletID = id
        request.mode = "foreground"
        try Task.checkCancellation()
        return try await call(request).checked()
    }
    private func call(_ request: AppletRequest) async throws -> AppletResponse {
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
                        let url = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: AppletConnection.providerID)
                    else {
                        throw AppletError(
                            "Install Noodle Applet to run noodlets. See Noodle Settings → Companion Apps."
                        )
                    }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    config.hides = true
                    config.arguments = ["--noodle-background"]
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
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
        sharedArtifacts = sharedArtifacts.filter { Date().timeIntervalSince($0.value.created) < 3600 }
        claimed = claimed.filter { Date().timeIntervalSince($0.value) < 300 }
        for agent in agents {
            guard (inFlight[agent.id] ?? 0) < 3, let token = tokens[agent.id],
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
                        from: MCPBridgeFiles.read(file, limit: AppletConnection.maxFrame))
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
                            response = AppletResponse(error: error.localizedDescription)
                        }
                        try? MCPBridgeFiles.write(response, to: output)
                    }
                    break
                } catch {
                    try? MCPBridgeFiles.write(
                        AppletResponse(error: error.localizedDescription), to: output)
                }
            }
        }
    }
    func perform(_ envelope: AppletAgentEnvelope, agent: AgentRecord) async throws -> AppletResponse
    {
        guard agents.contains(where: { $0.id == agent.id }) else {
            throw AppletError("This bot is no longer active.")
        }
        var request = envelope.request
        request.includePreview = nil
        request.owner = agent.id.uuidString.lowercased()
        try request.validate()
        if let conversation = envelope.conversationID {
            _ = try repository.participantRoster(for: agent.id, conversationID: conversation)
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
                    throw AppletError("Use --id with a shared noodlet link and --conversation.")
                }
                let messages = try repository.loadMessages(conversationID: conversation)
                let sent = Set(messages.flatMap(\.attachments))
                guard try repository.loadAttachments(conversationID: conversation).contains(where: {
                    sent.contains($0.id) && $0.url.flatMap(NoodletLink.id) == id
                }) else { throw AppletError("This noodlet has not been shared with the conversation.") }
                // The signed broker authorizes the specific shared package, never a caller-supplied path/session.
                request.owner = "local"
            }
        }
        if request.operation == .present, envelope.conversationID == nil {
            throw AppletError("Specify --conversation to share a preview.")
        }
        var response = try await call(request)
        response.previewBookmark = nil
        if response.error != nil { return response }
        guard agents.contains(where: { $0.id == agent.id }) else {
            throw AppletError("This bot was removed during the request.")
        }
        if let conversation = envelope.conversationID, let artifact = response.artifactID {
            sharedArtifacts[artifact] = (agent.id, conversation, request.owner!, Date())
        }
        if request.operation == .present, let conversation = envelope.conversationID {
            guard let url = response.url, NoodletLink.id(in: url) != nil else {
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
