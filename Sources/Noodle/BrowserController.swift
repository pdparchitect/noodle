import AppKit
import BrowserBridge
import Foundation
import NoodleCore
import Observation
import SwiftUI

@MainActor @Observable final class BrowserController {
    private(set) var registry = BrowserAssignments()
    private(set) var available = false
    private(set) var failure: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var claimed: [UUID: Date] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var bridgeMonitor: Task<Void, Never>?
    @ObservationIgnored private let mailboxMonitor = WorkspaceMailboxMonitor()
    @ObservationIgnored private var launching: Task<Void, Error>?
    @ObservationIgnored private let connection: (@Sendable (BrowserRequest) async throws -> BrowserResponse)?
    @ObservationIgnored private let transferRoot: URL?
    init(repository: WorkspaceRepository, transferRoot: URL? = nil, connection: (@Sendable (BrowserRequest) async throws -> BrowserResponse)? = nil) {
        self.repository = repository; self.connection = connection; self.transferRoot = transferRoot
        do { registry = try BrowserAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = error.localizedDescription }
    }
    var installed: Bool { BrowserApplication.locate() != nil }
    func start(agents: [AgentRecord], monitoring: Bool = true) {
        self.agents = agents; mailboxMonitor.reset()
        tokens = tokens.filter { id, _ in agents.contains { $0.id == id } }
        do {
            for agent in agents where tokens[agent.id] == nil {
                let workspace = repository.directory(for: agent)
                let folder = try BrowserAgentSkill.bridge(workspace: workspace)
                let token = UUID().uuidString + UUID().uuidString
                try MCPBridgeFiles.write(MCPBridgeSession(token: token, processID: getpid()), to: folder.appendingPathComponent("session.json"), workspace: workspace)
                tokens[agent.id] = token
            }
        } catch { failure = error.localizedDescription }
        guard monitoring else { return }
        if monitor == nil {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(launchIfNeeded: false)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        if bridgeMonitor == nil {
            bridgeMonitor = Task { [weak self] in
                while !Task.isCancelled { self?.scan(); try? await Task.sleep(for: .milliseconds(150)) }
            }
        }
    }
    func selectedIDs(for agent: AgentRecord) -> Set<UUID> { registry.assigned(to: agent.id) }
    func validate(_ ids: Set<UUID>) throws {
        guard readable, ids.isSubset(of: Set(registry.browsers.map(\.id))) else { throw BrowserError("One of the selected browsers is unavailable.") }
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL); registry = next
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    func reloadAssignments() throws {
        do { registry = try BrowserAssignments.load(root: repository.rootURL); readable = true }
        catch { readable = false; throw error }
    }
    func refresh(launchIfNeeded: Bool = false) async {
        do {
            let response = try await call(.init(.list), launchIfNeeded: launchIfNeeded).checked()
            guard let browsers = response.browsers, browsers.count <= 1000, Set(browsers.map(\.id)).count == browsers.count else { throw BrowserError("Invalid Browser catalogue.") }
            if readable, registry.browsers != browsers { var next = registry; next.browsers = browsers; try next.save(root: repository.rootURL); registry = next }
            available = true; if readable { failure = nil }
        } catch { available = false; if launchIfNeeded { failure = error.localizedDescription } }
    }
    func openLibrary() async throws {
        guard let url = BrowserApplication.locate() else { throw BrowserError("Build or install \(BrowserBuildIdentity.current.appName) first.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    func openDocument(at fileURL: URL) async throws {
        _ = try BrowserReference.read(fileURL)
        try Task.checkCancellation()
        guard let app = BrowserApplication.locate() else { throw BrowserError("Install \(BrowserBuildIdentity.current.appName) to open this page.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: configuration)
    }
    private func call(_ request: BrowserRequest, launchIfNeeded: Bool = true, authorize: () throws -> Void = {}) async throws -> BrowserResponse {
        try authorize()
        if let connection { return try await connection(request) }
        let socket = try BrowserConnection.socketURL(), team = try BrowserConnection.signingTeam()
        do { return try await BrowserConnection.call(request, socket: socket, team: team) }
        catch let error as BrowserError where error.unavailable && launchIfNeeded {
            if let launching { try await launching.value }
            else {
                let task = Task { @MainActor in
                    guard let url = BrowserApplication.locate() else { throw BrowserError("Install \(BrowserBuildIdentity.current.appName) to use assigned browsers.") }
                    _ = try await BrowserLaunch.openInBackground(at: url)
                }
                launching = task
                do { try await task.value; launching = nil } catch { launching = nil; throw error }
            }
            for _ in 0..<40 {
                try authorize()
                do { return try await BrowserConnection.call(request, socket: socket, team: team) }
                catch let error as BrowserError where error.unavailable { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw BrowserError("Noodle Browser did not become ready.")
        }
    }
    private func scan() {
        guard mailboxMonitor.hasChanges() else { return }
        claimed = claimed.filter { Date().timeIntervalSince($0.value) < 700 }
        for agent in agents {
            let workspace = repository.directory(for: agent)
            guard !pending.contains(agent.id), let token = tokens[agent.id], mailboxMonitor.needsScan(workspace: workspace, path: ".noodle/browser-bridge"),
                  let folder = try? BrowserAgentSkill.bridge(workspace: workspace),
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files.prefix(512) where file.pathExtension == "request" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), claimed[id] == nil else { continue }
                claimed[id] = Date()
                let output = folder.appendingPathComponent(id.uuidString.lowercased() + ".response")
                do {
                    let envelope = try JSONDecoder().decode(BrowserAgentRequest.self, from: MCPBridgeFiles.read(file, limit: 2 * 1_048_576, workspace: workspace))
                    guard envelope.id == id, envelope.token == token, envelope.expiresAt > Date(), envelope.expiresAt.timeIntervalSinceNow <= Double(envelope.request.operation.timeout + 5) else { throw BrowserError("Invalid or expired Browser session.") }
                    pending.insert(agent.id)
                    Task { [weak self] in
                        guard let self else { return }
                        defer { self.pending.remove(agent.id) }
                        let response: BrowserResponse
                        do { response = try await self.perform(envelope, agent: agent) }
                        catch { response = .init(error: error.localizedDescription) }
                        try? MCPBridgeFiles.write(response, to: output, workspace: workspace)
                    }
                    break
                } catch { try? MCPBridgeFiles.write(BrowserResponse(error: error.localizedDescription), to: output, workspace: workspace) }
            }
        }
    }
    func perform(_ envelope: BrowserAgentRequest, agent: AgentRecord) async throws -> BrowserResponse {
        func checkSession() throws {
            guard readable, tokens[agent.id] == envelope.token, agents.contains(where: { $0.id == agent.id }) else { throw BrowserError("This Browser agent session is no longer active.") }
        }
        try checkSession(); try envelope.request.validate()
        if envelope.request.operation == .present {
            guard let conversation = envelope.conversationID else { throw BrowserError("Specify the conversation for the browser card.") }
            _ = try repository.participantRoster(for: agent.id, conversationID: conversation)
        } else if envelope.conversationID != nil || envelope.message != nil {
            throw BrowserError("Conversation and message require present.")
        }
        if envelope.request.operation == .list {
            let response = try await call(.init(.list), authorize: checkSession).checked()
            try checkSession()
            var filtered = BrowserResponse()
            filtered.browsers = response.browsers?.filter { registry.permits($0.id, agent: agent.id) }
            return filtered
        }
        func checkAccess() throws {
            try checkSession()
            guard registry.permits(envelope.request.browserID, agent: agent.id) else { throw BrowserError("This browser is not assigned to you.") }
        }
        try checkAccess()
        var request = envelope.request
        // Agent JSON cannot select a staging location in the shared container.
        request.transferID = nil
        let response: BrowserResponse
        if request.operation.isFileTransfer {
            guard let path = envelope.localPath else { throw BrowserError("Specify a local workspace file.") }
            let root = try transferRoot ?? BrowserConnection.socketURL().deletingLastPathComponent()
            request.transferID = UUID()
            let staging = try BrowserTransferFiles.staging(root: root, id: request.transferID!, create: true)
            defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
            let workspace = repository.directory(for: agent)
            if request.operation == .upload {
                request.filename = (path as NSString).lastPathComponent
                let count = try await Task.detached { try ComputerWorkspaceFiles.upload(workspace: workspace, path: path, to: staging) }.value
                try checkAccess()
                response = try await call(request, authorize: checkAccess).checked()
                guard response.byteCount == count else { throw BrowserError("The browser did not confirm the complete upload.") }
            } else {
                let destination = try ComputerWorkspaceDownload(workspace: workspace, path: path)
                response = try await call(request, authorize: checkAccess).checked()
                try checkAccess()
                guard let size = response.byteCount, size >= 0, size <= BrowserTransferFiles.limit else { throw BrowserError("Invalid transferred file size.") }
                _ = try await Task.detached { try destination.copy(from: staging, expected: size) }.value
                try checkAccess(); try destination.publish()
            }
        } else {
            guard envelope.localPath == nil else { throw BrowserError("Local paths require a file transfer.") }
            response = try await call(request, authorize: checkAccess).checked()
        }
        try checkAccess()
        if let conversation = envelope.conversationID {
            _ = try repository.participantRoster(for: agent.id, conversationID: conversation)
            guard let reference = response.reference, reference.browser.id == request.browserID,
                  reference.tabID == request.tabID else { throw BrowserError("The browser returned a different page reference.") }
            try reference.validate()
            let card = BrowserCard(reference: reference, agentID: agent.id)
            let filename = String(reference.title.prefix(120)).replacingOccurrences(of: "/", with: "-")
            let attachment = try repository.importAttachment(data: JSONEncoder().encode(reference),
                originalFilename: (filename.isEmpty ? "Browser Page" : filename) + "." + BrowserBuildIdentity.current.fileExtension,
                into: conversation, mediaType: BrowserReference.mediaType, browser: card)
            do {
                _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation,
                    body: String((envelope.message ?? reference.title).prefix(10_000)), attachmentIDs: [attachment.id])
            } catch { try? repository.removeAttachment(attachment); throw error }
            // Keep the large saved snapshot in the attachment, out of the CLI result.
            var result = BrowserResponse(); result.attachmentID = attachment.id; result.tabID = reference.tabID
            return result
        }
        return response
    }
    deinit { monitor?.cancel(); bridgeMonitor?.cancel() }
}

struct BrowserAssignmentPicker: View {
    let controller: BrowserController
    @Binding var selectedIDs: Set<UUID>
    @State private var openingLibrary = false
    @State private var openError: String?

    var body: some View {
        CompanionAssignmentPicker(title: "Browsers", noun: "browser", symbol: "globe",
            items: controller.registry.browsers.map {
                CompanionAssignmentItem(id: $0.id, name: $0.name,
                    state: controller.available ? ($0.paused ? "Paused" : "Ready") : "Unavailable",
                    symbol: $0.symbol, colour: $0.colour, icon: $0.icon)
            }, selectedIDs: $selectedIDs, createPrompt: createPrompt, openLibraryButton: openLibraryButton,
            notice: EmptyView(), failure: controller.failure)
        .task { await controller.refresh(launchIfNeeded: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh(launchIfNeeded: true) }
        }
        .alert("Noodle Browser", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            if !controller.installed {
                Button("View Project") { NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!); openError = nil }
            }
            Button("OK") { openError = nil }
        } message: { Text(openError ?? "") }
    }
    private var createPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.largeTitle)
            Text(controller.available ? "No browsers yet" : "No browsers available")
            if controller.installed { openLibraryButton }
            else {
                Button("Get Noodle Browser…") { NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!) }
            }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
    private var openLibraryButton: some View {
        Button(openingLibrary ? "Opening…" : "Open Noodle Browser") {
            openingLibrary = true
            Task {
                defer { openingLibrary = false }
                do { try await controller.openLibrary() }
                catch { openError = error.localizedDescription }
            }
        }.disabled(openingLibrary)
    }
}
