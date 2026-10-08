import ComputerBridge
import ComputerCore
import ComputerExternal
import Foundation
import NoodleExternalToolsUI
import SwiftUI

/// Serves apps outside Noodle through noodle-computer while Settings allows them. Each sees only
/// computers it made or the person lent it, never the Hub's, and changes or deletes only those it
/// made; making one always asks the person, since a computer takes real disk space and time.
@MainActor final class ComputerExternalService {
    static private(set) var shared: ComputerExternalService?
    let gate: ExternalGate
    private let store: ComputerStore
    private let provider: ComputerProvider
    private let stagingRoot: URL?
    private let prompter = ExternalPrompter(appName: ComputerAppIdentity.name, noun: "computer")
    private var server: ExternalConnectionServer?

    /// `close` ends a caller's sessions on a computer it lost; tests watch it instead.
    init(store: ComputerStore, provider: ComputerProvider, gate: ExternalGate, stagingRoot: URL? = nil,
         close: ((ComputerRequest, String) async -> Void)? = nil) {
        self.store = store; self.provider = provider; self.gate = gate; self.stagingRoot = stagingRoot
        // A computer switched off for an app, or the app removed: its terminals there close too.
        let close = close ?? { request, peer in _ = try? await provider.handle(request, peer: peer) }
        gate.revoked = { caller, computers in
            let peer = Self.peer(caller)
            Task { for computer in computers { await close(ComputerRequest(.revoke, computerID: computer), peer) } }
        }
    }

    /// Who an outside app is to the provider: terminals it opens are its own.
    static func peer(_ caller: UUID) -> String { "external:" + caller.uuidString.lowercased() }

    /// Starts serving the app's library, with the person answering the questions.
    static func start(store: ComputerStore) {
        guard shared == nil, let provider = store.provider else { return }
        let gate = ExternalGate(url: ComputerExternal.grantsURL(library: store.library.root), prompter: nil)
        let service = ComputerExternalService(store: store, provider: provider, gate: gate)
        gate.prompter = service.prompter
        gate.enabledChanged = { [weak service] _ in service?.listen() }
        gate.prune(keeping: Set(store.sessions.map(\.id)))
        shared = service
        service.listen()
    }

    private func listen() {
        guard gate.enabled else { server = nil; return }
        guard server == nil else { return }
        do {
            let build = ComputerBuildIdentity.current, team = try ComputerConnection.signingTeam()
            server = try ExternalConnectionServer(socket: ComputerExternal.socketURL(), verify: { fd in
                // Only this app's own command-line tool, which names the app that runs it.
                try ExternalConnection.requireSigned(fd, identifier: build.cliID, team: team)
            }, handler: { [weak self] data in
                await self?.answer(data) ?? ExternalConnection.failure("Computer is closing.")
            })
        } catch { store.error = error.localizedDescription }
    }

    private func answer(_ data: Data) async -> Data {
        var response: ComputerResponse
        do {
            let envelope: ExternalEnvelope<ComputerRequest>
            do { envelope = try JSONDecoder().decode(ExternalEnvelope<ComputerRequest>.self, from: data) }
            catch { throw ComputerBridgeError("This needs a newer \(ComputerBuildIdentity.current.appName). Update it.") }
            response = try await perform(envelope.request, launcher: envelope.launcher)
        } catch { response = ComputerResponse(error: error.localizedDescription) }
        return (try? JSONEncoder().encode(response)) ?? ExternalConnection.failure("Could not answer.")
    }

    /// The sidebar's sections: this Mac's own computers, including any lent to an outside app;
    /// those an outside app made; and the Hub's.
    static func sections(_ sessions: [ComputerSession], created: Set<UUID>)
        -> (own: [ComputerSession], external: [ComputerSession], hub: [ComputerSession]) {
        let local = sessions.filter { $0.computer.hub != true }
        return (local.filter { !created.contains($0.id) }, local.filter { created.contains($0.id) }, sessions.filter { $0.computer.hub == true })
    }

    /// Computers a person may lend: their own, not the Hub's.
    static func lendable(_ store: ComputerStore) -> [ComputerSession] {
        store.sessions.filter { ComputerProvider.served($0.computer.kind) && $0.computer.hub != true }
    }

    func perform(_ input: ComputerRequest, launcher: ExternalLauncher) async throws -> ComputerResponse {
        guard ComputerOperation.externalCases.contains(input.operation) else { throw ComputerBridgeError("Apps outside Noodle cannot do that.") }
        let caller = try await gate.admit(launcher).id
        gate.prune(keeping: Set(store.sessions.map(\.id)))
        var request = input
        // Terminals belong to the calling app; it names no bot.
        request.agentID = nil
        try request.validate()
        let peer = Self.peer(caller)
        let lendable = Self.lendable(store)
        switch request.operation {
        case .list:
            var response = try await provider.handle(.init(.list), peer: peer)
            response.computers = response.computers?.filter { computer in gate.allows(caller, computer.id) && lendable.contains { $0.id == computer.id } }
            response.capabilities = nil
            return response
        case .templates:
            return try await provider.handle(request, peer: peer)
        case .create:
            guard let template = ContainerRegistry.bundled.templates.first(where: { $0.id == request.computer?.template }) else {
                throw ComputerBridgeError("\(ComputerAppIdentity.name) does not offer that kind of computer. Run templates.")
            }
            try await gate.confirm(for: caller, message: "“\(launcher.name)” wants to create a computer: \(template.name).", action: "Create")
            let response = try await provider.handle(request, peer: peer)
            for computer in response.computers ?? [] { gate.recordCreated(computer.id, by: caller) }
            return response
        case .borrow:
            let items = lendable.map { ExternalItem(id: $0.id, name: $0.computer.name, symbol: $0.computer.appearance?.iconSymbol ?? $0.computer.displaySymbol) }
            let picked = try await gate.borrow(for: caller, from: items)
            let listed = try await provider.handle(.init(.list), peer: peer)
            return ComputerResponse(computers: listed.computers?.filter { $0.id == picked })
        default:
            guard let id = request.computerID else { throw ComputerBridgeError("Specify --computer.") }
            try gate.require(caller, id)
            guard lendable.contains(where: { $0.id == id }) else { throw ComputerBridgeError("This computer belongs to Noodle Hub or no longer exists.") }
            if [.update, .delete].contains(request.operation), !gate.created(caller, id) {
                throw ComputerBridgeError("Only computers \(launcher.name) created can be changed or deleted.")
            }
            let staging = request.operation.isFileTransfer ? try stagingRoot ?? ComputerExternal.root() : nil
            let response = try await provider.handle(request, peer: peer, stagingRoot: staging)
            if request.operation == .delete { gate.forget(id) }
            return response
        }
    }
}

/// Settings > Agents.
struct ComputerExternalSettingsView: View {
    @State private var store: ComputerStore?
    var body: some View {
        Group {
            if let store, let service = ComputerExternalService.shared { Content(store: store, gate: service.gate) }
            else { Form { ProgressView() }.formStyle(.grouped) }
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .task { store = try? ComputerAppDelegate.loadLibrary() }
    }

    private struct Content: View {
        @ObservedObject var store: ComputerStore
        let gate: ExternalGate
        var body: some View {
            ExternalToolsSettingsView(gate: gate, noun: "computer",
                items: ComputerExternalService.lendable(store).map {
                    ExternalItem(id: $0.id, name: $0.computer.name, symbol: $0.computer.appearance?.iconSymbol ?? $0.computer.displaySymbol)
                },
                command: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/noodle-computer").path,
                server: ComputerBuildIdentity.current == .production ? "noodle-computer" : "noodle-computer-dev",
                delete: { ids in
                    Task {
                        for id in ids {
                            guard let session = store.sessions.first(where: { $0.id == id }), session.computer.kind == .container else { continue }
                            if session.phase != .stopped { await store.stop(session) }
                            if session.canDelete { store.remove(session) }
                        }
                    }
                })
        }
    }
}
