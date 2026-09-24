import AppKit
import ComputerBridge
import Foundation
import NoodleComputerTools
import NoodleCore
import Observation
import SwiftUI

@MainActor @Observable final class ComputerController {
    private(set) var registry = ComputerAssignments()
    private(set) var available = false
    private(set) var failure: String?
    private(set) var needsFileTransferUpdate = false
    private(set) var needsDocumentPreviewUpdate = false
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let socket: URL?
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var launch: Task<Void, Error>?
    @ObservationIgnored private let applicationLookup: @MainActor () -> URL?
    @ObservationIgnored private let documentOpener: (URL, URL) async throws -> Void
    /// Injectable connection boundary for deterministic broker failure tests.
    /// Normal app construction always uses the authenticated signed-app socket.
    @ObservationIgnored private let connection: (@Sendable (ComputerRequest) async throws -> ComputerResponse)?
    var installed: Bool { applicationLookup() != nil }

    init(repository: WorkspaceRepository, socket: URL? = nil,
         applicationLookup: @escaping @MainActor () -> URL? = { ComputerApplication.locate() },
         documentOpener: @escaping (URL, URL) async throws -> Void = { document, application in
             let configuration = NSWorkspace.OpenConfiguration()
             configuration.activates = true
             configuration.hides = false
             configuration.allowsRunningApplicationSubstitution = false
             configuration.promptsUserIfNeeded = false
             _ = try await NSWorkspace.shared.open([document], withApplicationAt: application, configuration: configuration)
         },
         connection: (@Sendable (ComputerRequest) async throws -> ComputerResponse)? = nil) {
        self.repository = repository
        self.socket = socket
        self.applicationLookup = applicationLookup
        self.documentOpener = documentOpener
        self.connection = connection
        do { registry = try ComputerAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = "Could not read Computer assignments; they were not changed." }
    }
    /// Bots reach computers through the Computer tool extension and Noodle's tool broker.
    /// This controller keeps the assignments, the Settings catalogue, and the clean-up of a
    /// bot's terminals when its access ends.
    func start(agents: [AgentRecord], monitoring: Bool = true) {
        for removed in self.agents where !agents.contains(where: { $0.id == removed.id }) {
            for id in registry.assigned(to: removed.id) {
                Task { [weak self] in _ = try? await self?.call(.init(.revoke, computerID: id, agentID: removed.id), launchIfNeeded: false) }
            }
        }
        self.agents = agents
        guard monitoring else {
            monitor?.cancel(); monitor = nil
            return
        }
        if monitor == nil {
            monitor = Task { [weak self] in
                await self?.refresh(launchIfNeeded: true)
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
    func call(_ request: ComputerRequest, launchIfNeeded: Bool = true,
              authorize: () throws -> Void = {}) async throws -> ComputerResponse {
        // Check before each action, including after a provider relaunch/update.
        // This inexpensive local handshake never replays the requested mutation.
        var handshake = ComputerRequest(.list)
        handshake.capabilitiesOnly = request.operation != .list
        let discovery = try await connect(handshake, launchIfNeeded: launchIfNeeded)
        try ComputerCapabilities.requireCompatible(discovery.capabilities)
        if request.operation.isFileTransfer { try ComputerCapabilities.requireFileTransfer(discovery.capabilities) }
        if request.operation == .preview { try ComputerCapabilities.requireDocumentPreview(discovery.capabilities) }
        try Task.checkCancellation()
        try authorize()
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
                throw ComputerBridgeError("Install \(ComputerBuildIdentity.current.appName) to use computers with your bots.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.hides = true
            configuration.allowsRunningApplicationSubstitution = false
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
            throw ComputerBridgeError("Install \(ComputerBuildIdentity.current.appName) to create a computer.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.allowsRunningApplicationSubstitution = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    /// A human opens the owned attachment through Computer's document handler.
    /// This does not use the agent broker or depend on any bot assignment.
    func openDocument(at fileURL: URL) async throws {
        guard fileURL.isFileURL, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ComputerBridgeError("This computer attachment is no longer available.")
        }
        if let launch { try await launch.value }
        try Task.checkCancellation()
        guard let application = applicationLookup() else {
            throw ComputerBridgeError("Install \(ComputerBuildIdentity.current.appName) to open this computer attachment.")
        }
        try await documentOpener(fileURL, application)
    }
    func openDownload() async throws {
        guard ComputerBuildIdentity.current != .development else {
            throw ComputerBridgeError("Build Noodle Computer Dev with scripts/build-and-launch-computer.sh to use computers in Noodle Dev.")
        }
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
        let id = UUID(); refreshID = id
        do {
            let response = try await call(.init(.list), launchIfNeeded: launchIfNeeded)
            guard refreshID == id, !Task.isCancelled else { return }
            guard let computers = response.computers, computers.count <= 1000,
                  Set(computers.map(\.id)).count == computers.count else { throw ComputerBridgeError("Invalid provider catalogue.") }
            available = true
            if readable, registry.computers != computers {
                var next = registry; next.computers = computers
                try next.save(root: repository.rootURL); registry = next
            }
            needsFileTransferUpdate = response.capabilities?.features.contains("file-transfer-v1") == false
            needsDocumentPreviewUpdate = response.capabilities?.features.contains("document-preview-v1") == false
            if readable { failure = nil }
        } catch {
            guard refreshID == id, !Task.isCancelled else { return }
            available = false; failure = error.localizedDescription
            needsFileTransferUpdate = false
            needsDocumentPreviewUpdate = false
        }
    }
    func selectedIDs(for agent: AgentRecord) -> Set<UUID> { registry.assigned(to: agent.id) }
    func validate(_ ids: Set<UUID>) throws {
        guard readable else { throw ComputerBridgeError("Computer assignments could not be read.") }
        guard ids.isSubset(of: Set(registry.computers.map(\.id))) else { throw ComputerBridgeError("One of the selected computers is no longer registered.") }
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids)
        let removed = registry.assigned(to: agent.id).subtracting(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL)
        registry = next // Access is revoked before asynchronous terminal cleanup.
        publishAssignments()
        for id in removed {
            Task { [weak self] in
                guard let self, !self.registry.permits(id, agent: agent.id) else { return }
                _ = try? await self.call(.init(.revoke, computerID: id, agentID: agent.id))
            }
        }
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    /// Receives each agent's assigned computer IDs for the tool broker, now and on every change.
    var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }
    /// A computer was unassigned while one of the bot's calls was running. Close what it opened.
    func revoke(computer: UUID, agent: UUID) {
        Task { [weak self] in
            guard let self, !self.registry.permits(computer, agent: agent) else { return }
            _ = try? await self.call(.init(.revoke, computerID: computer, agentID: agent))
        }
    }
    func reloadAssignments() throws {
        defer { publishAssignments() }
        do { registry = try ComputerAssignments.load(root: repository.rootURL); readable = true }
        catch { readable = false; throw error }
    }
    deinit { monitor?.cancel() }
}

struct ComputerAssignmentPicker: View {
    let controller: ComputerController
    @Binding var selectedIDs: Set<UUID>
    @State private var openingLibrary = false
    @State private var openError: String?

    var body: some View {
        CompanionAssignmentPicker(title: "Computers", noun: "computer", symbol: "desktopcomputer",
            items: controller.registry.computers.map {
                CompanionAssignmentItem(id: $0.id, name: $0.name, state: controller.available ? $0.state : "Unavailable",
                    symbol: $0.symbol, colour: $0.colour, icon: $0.icon, detail: $0.description)
            }, selectedIDs: $selectedIDs, createPrompt: createPrompt, openLibraryButton: openLibraryButton,
            notice: updateNotice, failure: controller.failure)
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

    @ViewBuilder private var updateNotice: some View {
        if controller.needsFileTransferUpdate || controller.needsDocumentPreviewUpdate {
            VStack(alignment: .leading, spacing: 8) {
                Label(controller.needsDocumentPreviewUpdate ? "Update Noodle Computer to enable native attachment previews." : "Update Noodle Computer to enable file transfers.", systemImage: "arrow.down.circle")
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
}
