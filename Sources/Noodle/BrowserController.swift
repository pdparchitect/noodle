import AppKit
import BrowserBridge
import Foundation
import HubLink
import NoodleCore
import NoodleHubClient
import Observation
import SwiftUI

@MainActor @Observable final class BrowserController {
    private(set) var registry = BrowserAssignments()
    private(set) var available = false
    private(set) var failure: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var launching: Task<Void, Error>?
    @ObservationIgnored private let connection: (@Sendable (BrowserRequest) async throws -> BrowserResponse)?
    /// Receives each agent's assigned browser IDs for the tool broker, now and on every change.
    @ObservationIgnored var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }
    init(repository: WorkspaceRepository, connection: (@Sendable (BrowserRequest) async throws -> BrowserResponse)? = nil) {
        self.repository = repository; self.connection = connection
        do { registry = try BrowserAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = error.localizedDescription }
    }
    var installed: Bool { BrowserApplication.locate() != nil }
    /// Bots reach browsers through the Browser tool extension. This controller keeps the
    /// assignments and the catalogue shown in Settings.
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
    func validate(_ ids: Set<UUID>) throws {
        guard readable, ids.isSubset(of: Set(registry.browsers.map(\.id))) else { throw BrowserError("One of the selected browsers is unavailable.") }
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL); registry = next
        publishAssignments()
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    func reloadAssignments() throws {
        defer { publishAssignments() }
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
    /// Makes a browser in Noodle Browser and lists it here.
    func create(_ draft: BrowserDraft) async throws -> RemoteBrowser {
        var request = BrowserRequest(.create)
        request.profile = draft
        guard let made = try await call(request).checked().browser else {
            throw BrowserError("\(BrowserBuildIdentity.current.appName) did not return the new browser. Update it and try again.")
        }
        await refresh()
        return made
    }
    /// Deletes a browser in Noodle Browser, with its signed-in sessions and history.
    func delete(_ id: UUID) async throws {
        _ = try await call(BrowserRequest(.delete, browserID: id)).checked()
        await refresh()
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
    deinit { monitor?.cancel() }
}

struct BrowserAssignmentPicker: View {
    let controller: BrowserController
    @Binding var selectedIDs: Set<UUID>
    @State private var openingLibrary = false
    @State private var openError: String?
    @State private var creating = false

    var body: some View {
        CompanionAssignmentPicker(title: "Browsers", noun: "browser", symbol: "globe",
            items: controller.registry.browsers.map {
                CompanionAssignmentItem(id: $0.id, name: $0.name,
                    state: controller.available ? ($0.paused ? "Paused" : "Ready") : "Unavailable",
                    symbol: $0.symbol, colour: $0.colour, icon: $0.icon, detail: $0.description)
            }, selectedIDs: $selectedIDs, createPrompt: createPrompt, openLibraryButton: openLibraryButton,
            notice: EmptyView(), failure: controller.failure,
            onNew: controller.installed ? { creating = true } : nil,
            onDelete: { item in
                Task {
                    do { try await controller.delete(item.id) }
                    catch { openError = error.localizedDescription }
                }
            })
        .sheet(isPresented: $creating) {
            NewBrowserSheet(create: controller.create) { selectedIDs.insert($0.id) }
        }
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

/// Makes a browser, on this Mac or on a Noodle Hub.
struct NewBrowserSheet: View {
    let create: (BrowserDraft) async throws -> RemoteBrowser
    let onCreated: (RemoteBrowser) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Browser"
    @State private var description = ""
    @State private var making = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(making)
                Spacer()
                Text("New Browser").font(.headline)
                Spacer()
                Button("Create", action: make).keyboardShortcut(.defaultAction)
                    .disabled(making || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
            Divider()
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, prompt: Text("Optional"), axis: .vertical).lineLimit(2...3)
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(making)
        }
        .frame(width: 420)
    }

    private func make() {
        making = true
        failure = nil
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { making = false }
            do {
                let made = try await create(BrowserDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         description: text.isEmpty ? nil : text))
                onCreated(made)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

/// The Browsers tab of a bot kept on a Noodle Hub: the person's browsers there, in Noodle
/// Browser on the Hub's Mac.
struct HubBrowserPicker: View {
    let mirror: HubMirror
    @Binding var selectedIDs: Set<UUID>
    @State private var creating = false
    @State private var failure: String?

    var body: some View {
        CompanionAssignmentPicker(title: "Browsers", noun: "browser", symbol: "globe",
            items: mirror.browsers.map {
                CompanionAssignmentItem(id: $0.id, name: $0.name, state: $0.paused ? "Paused" : "Ready", symbol: $0.symbol,
                                        colour: $0.colour, icon: $0.icon, detail: $0.description)
            }, selectedIDs: $selectedIDs,
            createPrompt: VStack(spacing: 10) {
                Image(systemName: "globe").font(.largeTitle)
                Text("No browsers on this Hub")
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity),
            openLibraryButton: EmptyView(), notice: EmptyView(), failure: failure, onNew: { creating = true },
            onDelete: { item in
                failure = nil
                Task {
                    do { try await mirror.deleteBrowser(item.id) }
                    catch { failure = error.localizedDescription }
                }
            })
        .sheet(isPresented: $creating) {
            NewBrowserSheet(create: { draft in
                let made = try await mirror.createBrowser(LinkBrowserDraft(name: draft.name, description: draft.description,
                                                                           symbol: draft.symbol, colour: draft.colour))
                return RemoteBrowser(id: made.id, name: made.name, description: made.description, symbol: made.symbol,
                                     colour: made.colour, icon: made.icon, paused: made.paused)
            }) { selectedIDs.insert($0.id) }
        }
    }
}
