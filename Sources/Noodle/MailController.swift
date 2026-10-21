import AppKit
import Foundation
import MailBridge
import NoodleCore
import Observation
import SwiftUI

/// Keeps which bots may use which Noodle Mail mailboxes, and the mailbox list Edit Bot shows.
/// Bots reach mail through the Mail tool extension; Noodle's tool broker enforces these assignments.
@MainActor @Observable final class MailController {
    private(set) var registry = MailAssignments()
    private(set) var available = false
    private(set) var failure: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var launching: Task<Void, Error>?
    @ObservationIgnored private let connection: (@Sendable (MailRequest) async throws -> MailResponse)?
    /// Receives each agent's assigned mailbox IDs for the tool broker, now and on every change.
    @ObservationIgnored var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }

    init(repository: WorkspaceRepository, connection: (@Sendable (MailRequest) async throws -> MailResponse)? = nil) {
        self.repository = repository; self.connection = connection
        do { registry = try MailAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = error.localizedDescription }
    }
    var installed: Bool { MailApplication.locate() != nil }
    /// Keeps the mailbox list current while Noodle Mail runs, without starting it.
    func start(agents: [AgentRecord], monitoring: Bool = true) {
        guard monitoring, monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(launchIfNeeded: false)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func selectedIDs(for agent: AgentRecord) -> Set<UUID> { registry.assigned(to: agent.id) }
    /// Mailboxes the bot already has stay with it when Noodle Mail no longer lists them; only added ones must be listed.
    func validate(_ ids: Set<UUID>, for agent: AgentRecord? = nil) throws {
        guard readable, ids.subtracting(agent.map(selectedIDs) ?? []).isSubset(of: Set(registry.mailboxes.map(\.id))) else {
            throw MailError("One of the selected mailboxes is unavailable.")
        }
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids, for: agent)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL); registry = next
        publishAssignments()
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    func reloadAssignments() throws {
        defer { publishAssignments() }
        do { registry = try MailAssignments.load(root: repository.rootURL); readable = true }
        catch { readable = false; throw error }
    }
    func refresh(launchIfNeeded: Bool = false) async {
        do {
            let response = try await call(MailRequest(.mailboxes), launchIfNeeded: launchIfNeeded).checked()
            guard let mailboxes = response.mailboxes, mailboxes.count <= 1000, Set(mailboxes.map(\.id)).count == mailboxes.count else {
                throw MailError("Invalid Noodle Mail mailbox list.")
            }
            if readable, registry.mailboxes != mailboxes { var next = registry; next.mailboxes = mailboxes; try next.save(root: repository.rootURL); registry = next }
            available = true; if readable { failure = nil }
        } catch { available = false; if launchIfNeeded { failure = error.localizedDescription } }
    }
    func openLibrary() async throws {
        guard let url = MailApplication.locate() else { throw MailError("Build or install \(MailBuildIdentity.current.appName) first.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    private func call(_ request: MailRequest, launchIfNeeded: Bool = true) async throws -> MailResponse {
        if let connection { return try await connection(request) }
        let socket = try MailConnection.socketURL(), team = try MailConnection.signingTeam()
        do { return try await MailConnection.call(request, socket: socket, team: team) }
        catch let error as MailError where error.unavailable && launchIfNeeded {
            if let launching { try await launching.value }
            else {
                let task = Task { @MainActor in
                    guard let url = MailApplication.locate() else { throw MailError("Install \(MailBuildIdentity.current.appName) to use assigned mailboxes.") }
                    _ = try await MailLaunch.openInBackground(at: url)
                }
                launching = task
                do { try await task.value; launching = nil } catch { launching = nil; throw error }
            }
            for _ in 0..<40 {
                do { return try await MailConnection.call(request, socket: socket, team: team) }
                catch let error as MailError where error.unavailable { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw MailError("\(MailBuildIdentity.current.appName) did not start in time. Try again in a moment.")
        }
    }
    deinit { monitor?.cancel() }
}

struct MailAssignmentPicker: View {
    let controller: MailController
    let bot: String
    @Binding var selectedIDs: Set<UUID>
    @State private var openingLibrary = false
    @State private var openError: String?

    var body: some View {
        CompanionAssignmentPicker(title: "Mailboxes", noun: "mailbox", symbol: "envelope",
            items: controller.registry.mailboxes.map {
                CompanionAssignmentItem(id: $0.id, name: $0.name, state: controller.available ? "Ready" : "Unavailable",
                                        symbol: "envelope", colour: 0, detail: $0.address)
            }, selectedIDs: $selectedIDs, createPrompt: createPrompt,
            openLibraryButton: Group { if controller.installed { openLibraryButton } }, notice: EmptyView(), failure: controller.failure)
        .task { await controller.refresh(launchIfNeeded: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh(launchIfNeeded: true) }
        }
        .alert(MailBuildIdentity.current.appName, isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") { openError = nil }
        } message: { Text(openError ?? "") }
    }
    private var createPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope").font(.largeTitle)
            Text(controller.available ? "No mailboxes yet" : "No mailboxes available")
            if !controller.installed { Text("Install \(MailBuildIdentity.current.appName) to add mailboxes.") }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
    /// Sits in the chooser footer.
    private var openLibraryButton: some View {
        let title = openingLibrary ? "Opening…" : "Open App"
        return Button {
            openingLibrary = true
            Task {
                defer { openingLibrary = false }
                do { try await controller.openLibrary() }
                catch { openError = error.localizedDescription }
            }
        } label: {
            Label(title, systemImage: "arrow.up.forward.app")
        }
        .help("Open Noodle Mail").accessibilityLabel(openingLibrary ? "Opening…" : "Open Noodle Mail")
        .disabled(openingLibrary)
    }
}
