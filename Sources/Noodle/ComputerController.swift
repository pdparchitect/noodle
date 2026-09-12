import AppKit
import ComputerBridge
import Foundation
import NoodleCore
import Observation
import SwiftUI

@MainActor @Observable final class ComputerController {
    private(set) var registry = ComputerAssignments()
    private(set) var available = false
    private(set) var failure: String?
    private(set) var needsFileTransferUpdate = false
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let socket: URL?
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var bridge: Task<Void, Never>?
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var claimed: [UUID: Date] = [:]
    @ObservationIgnored private var launch: Task<Void, Error>?
    @ObservationIgnored private let applicationLookup: () -> URL?
    /// Injectable connection boundary for deterministic broker failure tests.
    /// Normal app construction always uses the authenticated signed-app socket.
    @ObservationIgnored private let connection: (@Sendable (ComputerRequest) async throws -> ComputerResponse)?
    var installed: Bool { applicationLookup() != nil }

    init(repository: WorkspaceRepository, socket: URL? = nil,
         applicationLookup: @escaping () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ComputerConnection.providerID) },
         connection: (@Sendable (ComputerRequest) async throws -> ComputerResponse)? = nil) {
        self.repository = repository
        self.socket = socket
        self.applicationLookup = applicationLookup
        self.connection = connection
        do { registry = try ComputerAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = "Could not read Computer assignments; they were not changed." }
    }
    func start(agents: [AgentRecord]) {
        for removed in self.agents where !agents.contains(where: { $0.id == removed.id }) {
            for id in registry.assigned(to: removed.id) {
                Task { [weak self] in _ = try? await self?.call(.init(.revoke, computerID: id, agentID: removed.id), launchIfNeeded: false) }
            }
        }
        self.agents = agents
        tokens = tokens.filter { id, _ in agents.contains { $0.id == id } }
        do {
            for agent in agents where tokens[agent.id] == nil {
                let directory = try ComputerAgentSkill.bridge(workspace: repository.directory(for: agent))
                let token = UUID().uuidString + UUID().uuidString
                tokens[agent.id] = token
                try MCPBridgeFiles.write(MCPBridgeSession(token: token, processID: getpid()), to: directory.appendingPathComponent("session.json"))
            }
        } catch { failure = error.localizedDescription }
        if monitor == nil {
            monitor = Task { [weak self] in
                await self?.refresh(launchIfNeeded: true)
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        if bridge == nil {
            bridge = Task { [weak self] in
                while !Task.isCancelled {
                    self?.scan()
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
    }
    func call(_ request: ComputerRequest, launchIfNeeded: Bool = true) async throws -> ComputerResponse {
        // Check before each action, including after a provider relaunch/update.
        // This inexpensive local handshake never replays the requested mutation.
        var handshake = ComputerRequest(.list)
        handshake.capabilitiesOnly = request.operation != .list
        let discovery = try await connect(handshake, launchIfNeeded: launchIfNeeded)
        try ComputerCapabilities.requireCompatible(discovery.capabilities)
        if request.operation.isFileTransfer { try ComputerCapabilities.requireFileTransfer(discovery.capabilities) }
        if request.operation == .list { return discovery }
        return try await connect(request, launchIfNeeded: false)
    }
    private func connect(_ request: ComputerRequest, launchIfNeeded: Bool) async throws -> ComputerResponse {
        if let connection { return try await connection(request) }
        let endpoint = try socket ?? ComputerConnection.socketURL(), team = try ComputerConnection.signingTeam()
        do { return try await ComputerConnection.call(request, socket: endpoint, team: team) }
        catch let error as ComputerBridgeError where error.unavailable && launchIfNeeded && socket == nil {
            try await launchProvider()
            // Only connect failures are retried. A sent mutation with an uncertain
            // result is never repeated automatically.
            for attempt in 0..<40 {
                do { return try await ComputerConnection.call(request, socket: endpoint, team: team) }
                catch let error as ComputerBridgeError where error.unavailable && attempt < 39 {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw ComputerBridgeError("Computer did not become ready.")
        }
    }
    private func launchProvider() async throws {
        if let launch { try await launch.value; return }
        let task = Task { @MainActor in
            guard let url = self.applicationLookup() else {
                throw ComputerBridgeError("Install Noodle Computer to use computers with your bots.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.hides = true
            configuration.arguments = ["--noodle-background"]
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        launch = task
        defer { launch = nil }
        try await task.value
    }
    /// Explicit user action: bring the library forward instead of quiet discovery.
    func openLibrary() async throws {
        if let launch { try await launch.value }
        guard let url = applicationLookup() else {
            throw ComputerBridgeError("Install Noodle Computer to create a computer.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    func openDownload() async throws {
        // Do not send users to a broken download before the first public release.
        var request = URLRequest(url: ComputerDistribution.releaseAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ComputerBridgeError("Could not check Computer downloads. Try again later.") }
        try ComputerDistribution.validateDownloadStatus(response.statusCode)
        try Task.checkCancellation()
        guard NSWorkspace.shared.open(ComputerDistribution.downloadPage) else { throw ComputerBridgeError("Could not open the Computer download page.") }
    }
    func refresh(launchIfNeeded: Bool = false) async {
        do {
            let response = try await call(.init(.list), launchIfNeeded: launchIfNeeded)
            guard let computers = response.computers, computers.count <= 1000,
                  Set(computers.map(\.id)).count == computers.count else { throw ComputerBridgeError("Invalid provider catalogue.") }
            available = true
            if readable, registry.computers != computers {
                var next = registry; next.computers = computers
                try next.save(root: repository.rootURL); registry = next
            }
            needsFileTransferUpdate = response.capabilities?.features.contains("file-transfer-v1") == false
            if readable { failure = nil }
        } catch {
            available = false; failure = error.localizedDescription
            needsFileTransferUpdate = false
        }
    }
    func selectedIDs(for agent: AgentRecord) -> Set<UUID> { registry.assigned(to: agent.id) }
    func validate(_ ids: Set<UUID>) throws {
        guard readable else { throw ComputerBridgeError("Computer assignments could not be read.") }
        guard ids.isSubset(of: Set(registry.computers.map(\.id))) else { throw ComputerBridgeError("One of the selected computers is no longer registered.") }
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord) throws {
        try validate(ids)
        let removed = registry.assigned(to: agent.id).subtracting(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL)
        registry = next // Access is revoked before asynchronous terminal cleanup.
        try repository.synchronizeAgentWorkspace(agent)
        for id in removed {
            Task { [weak self] in _ = try? await self?.call(.init(.revoke, computerID: id, agentID: agent.id)) }
        }
    }
    func permits(_ card: ComputerCard) -> Bool {
        readable && registry.permits(card.computer.id, agent: card.agentID) && agents.contains { $0.id == card.agentID }
    }
    func previewCall(_ request: ComputerRequest, card: ComputerCard) async throws -> ComputerResponse {
        try request.validate()
        guard [.terminalRead, .terminalWrite, .terminalResize, .display].contains(request.operation),
              permits(card), request.computerID == card.computer.id,
              request.agentID == card.agentID, request.terminalID == card.terminalID else {
            throw ComputerBridgeError("This computer assignment or terminal reference has been revoked.")
        }
        let response = try await call(request)
        guard permits(card) else { throw ComputerBridgeError("This computer assignment was revoked.") }
        return response
    }
    private func scan() {
        claimed = claimed.filter { Date().timeIntervalSince($0.value) < 700 }
        for agent in agents {
            guard !pending.contains(agent.id), let token = tokens[agent.id],
                  let directory = try? ComputerAgentSkill.bridge(workspace: repository.directory(for: agent)),
                  let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files.prefix(512) where file.pathExtension == "request" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), claimed[id] == nil else { continue }
                claimed[id] = Date()
                let resultURL = directory.appendingPathComponent(id.uuidString.lowercased() + ".response")
                do {
                    let envelope = try JSONDecoder().decode(ComputerAgentRequest.self, from: MCPBridgeFiles.read(file, limit: 150_000))
                    guard envelope.id == id, envelope.token == token, envelope.expiresAt > Date(),
                          envelope.expiresAt.timeIntervalSinceNow <= Double(envelope.request.operation.timeout + 5) else { throw ComputerBridgeError("Invalid or expired Computer session.") }
                    pending.insert(agent.id)
                    Task { [weak self] in
                        guard let self else { return }
                        defer { self.pending.remove(agent.id) }
                        let response: ComputerResponse
                        do { response = try await self.perform(envelope, agent: agent) }
                        catch { response = .init(error: error.localizedDescription) }
                        try? ComputerAgentFiles.write(response, to: resultURL)
                    }
                    break
                } catch { try? ComputerAgentFiles.write(ComputerResponse(error: error.localizedDescription), to: resultURL) }
            }
        }
    }
    private func perform(_ envelope: ComputerAgentRequest, agent: AgentRecord) async throws -> ComputerResponse {
        guard readable, agents.contains(where: { $0.id == agent.id }) else { throw ComputerBridgeError("Computer access is unavailable.") }
        var request = envelope.request
        request.agentID = agent.id // Agent identity is broker-owned, never trusted from CLI JSON.
        try request.validate()
        guard ![.revoke, .display, .terminalResolve].contains(request.operation) else { throw ComputerBridgeError("This operation is user-only.") }
        if request.operation == .list {
            let response = try await call(.init(.list))
            var result = ComputerResponse(computers: response.computers?.filter { registry.permits($0.id, agent: agent.id) })
            result.capabilities = response.capabilities
            return result
        }
        if let conversation = envelope.conversationID {
            guard request.operation == .preview, envelope.view == nil || ["terminal", "web"].contains(envelope.view!) else {
                throw ComputerBridgeError("Invalid computer preview request.")
            }
            _ = try repository.participantRoster(for: agent.id, conversationID: conversation)
        }
        if request.operation == .preview {
            guard envelope.conversationID != nil else { throw ComputerBridgeError("Specify the conversation for the computer card.") }
            request.view = envelope.view
            if request.computerID == nil {
                // Resolve only the authenticated agent's own session. No output or
                // credentials are fetched until the resolved assignment is checked.
                let resolved = try await call(.init(.terminalResolve, agentID: agent.id, terminalID: request.terminalID))
                request.computerID = resolved.computerID
            }
        }
        guard registry.permits(request.computerID, agent: agent.id) else { throw ComputerBridgeError("This computer is not assigned to you.") }
        let response: ComputerResponse
        if request.operation.isFileTransfer {
            guard let localPath = envelope.localPath else { throw ComputerBridgeError("Specify a local workspace file.") }
            response = try await transfer(request, localPath: localPath, agent: agent)
        } else {
            guard envelope.localPath == nil else { throw ComputerBridgeError("Local paths require upload or download.") }
            response = try await call(request)
        }
        guard registry.permits(request.computerID, agent: agent.id), agents.contains(where: { $0.id == agent.id }) else {
            _ = try? await call(.init(.revoke, computerID: request.computerID, agentID: agent.id))
            throw ComputerBridgeError("Computer access was revoked during the request.")
        }
        if let conversation = envelope.conversationID,
           let computer = registry.computers.first(where: { $0.id == request.computerID }) {
            let text = String(decoding: response.data ?? Data(), as: UTF8.self)
                .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            let view = response.view ?? envelope.view ?? (request.terminalID != nil ? "terminal" : (computer.hasWebDisplay == true ? "web" : "terminal"))
            guard view != "web" || computer.hasWebDisplay == true else { throw ComputerBridgeError("This computer has no web display.") }
            let terminal = view == "terminal" ? (response.terminalID ?? request.terminalID) : nil
            guard view == "web" || terminal != nil else { throw ComputerBridgeError("The provider did not return a terminal session. Update Noodle Computer.") }
            let card = ComputerCard(computer: computer, agentID: agent.id, terminalID: terminal, terminalPreview: text,
                view: view, previewImage: view == "web" ? response.previewImage : nil)
            let attachment = try repository.importAttachment(data: JSONEncoder().encode(card), originalFilename: computer.name + ".noodlecomputer",
                into: conversation, mediaType: ComputerCard.mediaType, computer: card)
            do {
                _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation,
                    body: String((envelope.message ?? "Open \(computer.name)").prefix(10_000)), attachmentIDs: [attachment.id])
            } catch { try? repository.removeAttachment(attachment); throw error }
        }
        return response
    }
    private func transfer(_ input: ComputerRequest, localPath: String, agent: AgentRecord) async throws -> ComputerResponse {
        func checkAccess() throws {
            guard registry.permits(input.computerID, agent: agent.id), agents.contains(where: { $0.id == agent.id }) else {
                throw ComputerBridgeError("Computer access was revoked during the transfer.")
            }
        }
        // Reject old providers before copying a potentially large local file.
        let discovery = try await call(.init(.list))
        try ComputerCapabilities.requireFileTransfer(discovery.capabilities)
        try checkAccess()
        let root = try (socket ?? ComputerConnection.socketURL()).deletingLastPathComponent()
        var request = input
        request.transferID = UUID() // Ignore any agent-supplied staging reference.
        let staging = try ComputerTransferFiles.staging(root: root, id: request.transferID!, create: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let workspace = repository.directory(for: agent)
        if request.operation == .fileUpload {
            let count = try await Task.detached {
                try ComputerWorkspaceFiles.upload(workspace: workspace, path: localPath, to: staging)
            }.value
            try checkAccess()
            let response = try await call(request)
            guard response.byteCount == count else { throw ComputerBridgeError("The provider did not confirm the complete upload. Check the guest file before retrying.") }
            return response
        }
        let destination = try ComputerWorkspaceDownload(workspace: workspace, path: localPath)
        let response = try await call(request)
        try checkAccess()
        guard let count = response.byteCount, count >= 0, count <= ComputerTransferFiles.limit else {
            throw ComputerBridgeError("The provider returned an invalid download size.")
        }
        _ = try await Task.detached { try destination.copy(from: staging, expected: count) }.value
        try checkAccess()
        try destination.publish()
        return response
    }
    deinit { monitor?.cancel(); bridge?.cancel() }
}

struct ComputerAssignmentPicker: View {
    let controller: ComputerController
    @Binding var selectedIDs: Set<UUID>
    @State private var showingAdd = false
    @State private var search = ""
    @State private var openingLibrary = false
    @State private var openError: String?

    private var selected: [RemoteComputer] {
        let known = controller.registry.computers.filter { selectedIDs.contains($0.id) }
        let missing = selectedIDs.subtracting(controller.registry.computers.map(\.id))
            .sorted { $0.uuidString < $1.uuidString }
            .map { RemoteComputer(id: $0, name: "Unavailable computer", kind: "", state: "Unavailable",
                                  symbol: "questionmark", colour: 0) }
        return known + missing
    }
    private var available: [RemoteComputer] {
        controller.registry.computers.filter {
            !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Computers").font(.caption.weight(.semibold))
                Spacer()
                Button { search = ""; showingAdd = true } label: {
                    Label("Add Computers", systemImage: "plus")
                }
                .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                    VStack(spacing: 12) {
                        TextField("Search computers", text: $search).textFieldStyle(.roundedBorder)
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(available) { computer in
                                    Button { selectedIDs.insert(computer.id) } label: {
                                        HStack(spacing: 12) {
                                            avatar(computer, size: 32)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(computer.name).foregroundStyle(.primary)
                                                Text(controller.available ? computer.state : "Unavailable")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                        }
                                        .padding(8).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Add \(computer.name) to bot")
                                }
                                if controller.registry.computers.isEmpty {
                                    createPrompt
                                } else if available.isEmpty {
                                    Text(search.isEmpty ? "All computers added" : "No matching computers")
                                        .foregroundStyle(.secondary).padding()
                                }
                            }
                        }
                        HStack {
                            if !controller.registry.computers.isEmpty { openLibraryButton }
                            Spacer()
                            Button("Done") { showingAdd = false }
                        }
                    }
                    .padding(16).frame(width: 300, height: 280)
                }
            }
            if controller.needsFileTransferUpdate {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Update Noodle Computer to enable file transfers.", systemImage: "arrow.down.circle")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("In Noodle Computer, choose Check for Updates… from the app menu.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    openLibraryButton
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ComputerUpdateNotice")
            }
            ScrollView {
                if selected.isEmpty {
                    if controller.registry.computers.isEmpty {
                        createPrompt.padding(.vertical, 24)
                    } else {
                        Button { search = ""; showingAdd = true } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "desktopcomputer").font(.largeTitle)
                                Text("Add computers to this bot")
                            }
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            .padding(.vertical, 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Add computers to this bot")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 16) {
                        ForEach(selected) { computer in
                            VStack(spacing: 8) {
                                avatar(computer, size: 48)
                                    .overlay(alignment: .topTrailing) {
                                        Button { selectedIDs.remove(computer.id) } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 17)).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color(nsColor: .darkGray))
                                                .padding(4).contentShape(Circle())
                                        }
                                        .buttonStyle(.plain).offset(x: 10, y: -8)
                                        .help("Remove \(computer.name) from bot")
                                        .accessibilityLabel("Remove \(computer.name) from bot")
                                    }
                                Text(computer.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                            .help("\(computer.name) · \(controller.available ? computer.state : "Unavailable")")
                        }
                    }.padding(12)
                }
            }
            .frame(minHeight: 140, maxHeight: 280)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            Text("Computers can be shared with multiple bots. Their files and services are shared; terminal sessions are separate.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure = controller.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await controller.refresh(launchIfNeeded: true) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == getpid() else { return }
            Task { await controller.refresh(launchIfNeeded: true) }
        }
        .alert("Noodle Computer", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            if !controller.installed {
                Button("View Project") { NSWorkspace.shared.open(ComputerDistribution.documentation); openError = nil }
            }
            Button("OK") { openError = nil }
        } message: { Text(openError ?? "") }
    }

    private var createPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.largeTitle)
            Text(controller.available ? "No computers yet" : "No computers available")
            Text(controller.installed ? "Open Noodle Computer to create one, then return here to add it." :
                    "Install Noodle Computer to create your first computer.")
                .font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if controller.installed { openLibraryButton }
            else {
                Button(openingLibrary ? "Checking…" : "Get Noodle Computer…") {
                    openingLibrary = true
                    Task {
                        defer { openingLibrary = false }
                        do { try await controller.openDownload() }
                        catch { openError = error.localizedDescription }
                    }
                }.disabled(openingLibrary)
                Text("Apple silicon · macOS 26 or later").font(.caption2)
            }
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }

    private var openLibraryButton: some View {
        Button(openingLibrary ? "Opening…" : "Open Noodle Computer") {
            openingLibrary = true
            Task {
                defer { openingLibrary = false }
                do { try await controller.openLibrary() }
                catch { openError = error.localizedDescription }
            }
        }.disabled(openingLibrary)
    }

    private func avatar(_ computer: RemoteComputer, size: CGFloat) -> some View {
        var agent = AgentRecord(displayName: computer.name, accentSeed: 0)
        agent.avatarSymbolName = computer.symbol
        agent.avatarColorIndex = abs(computer.colour % BotAvatarPalette.gradients.count)
        agent.avatarImageData = computer.icon
        return BotAvatar(agent: agent, size: size)
    }
}
