import AppKit
import ComputerBridge
import Containerization
import Darwin
import Foundation
import WebKit

@MainActor final class ComputerProvider {
    private weak var store: ComputerStore?
    private var server: ComputerConnectionServer?
    private var terminals: [UUID: ProviderTerminal] = [:]
    private let transferRoot: URL

    init(store: ComputerStore, socket: URL? = nil) throws {
        self.store = store
        let endpoint = try socket ?? ComputerConnection.socketURL()
        transferRoot = endpoint.deletingLastPathComponent()
        let clients = socket == nil ? ComputerConnection.clientIDs : ComputerConnection.clientIDs + ["com.pdparchitect.noodle.integration"]
        server = try ComputerConnectionServer(socket: endpoint, team: ComputerConnection.signingTeam(), clientIDs: clients) {
            [weak self] request, peer in
            guard let self else { return .init(error: "Computer is closing.") }
            return await self.respond(request, peer: peer)
        }
    }
    private func respond(_ request: ComputerRequest, peer: String) async -> ComputerResponse {
        do { return try await handle(request, peer: peer) }
        catch { return .init(error: error.localizedDescription) }
    }
    private func handle(_ request: ComputerRequest, peer: String) async throws -> ComputerResponse {
        guard let store else { throw ComputerBridgeError("Computer is closing.") }
        let owner = peer + ":" + (request.agentID?.uuidString ?? "human")
        if request.operation == .terminalResolve {
            guard let id = request.terminalID, let terminal = terminals[id], terminal.owner == owner else {
                throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
            }
            var response = ComputerResponse()
            response.computerID = terminal.computerID
            return response
        }
        if request.operation == .list {
            if request.capabilitiesOnly == true {
                var response = ComputerResponse()
                response.capabilities = ComputerCapabilities()
                return response
            }
            var response = ComputerResponse(computers: store.sessions.filter { $0.computer.kind == .container }.map { session in
                let appearance = session.computer.appearance
                let icon = appearance?.iconImage
                return RemoteComputer(id: session.id, name: session.computer.name, kind: session.computer.displayType,
                    state: session.phase.label, symbol: appearance?.iconSymbol ?? session.computer.displaySymbol,
                    colour: appearance?.iconColour ?? 0, icon: (icon?.count ?? 0) <= 65_536 ? icon : nil,
                    hasWebDisplay: session.desktop != nil)
            })
            response.capabilities = ComputerCapabilities()
            return response
        }
        guard let session = store.sessions.first(where: { $0.id == request.computerID }), session.computer.kind == .container else {
            throw ComputerBridgeError("This computer no longer exists or is not supported by this provider version.")
        }
        if request.operation == .revoke {
            let ids = terminals.filter { $0.value.owner == owner && $0.value.computerID == session.id }.map(\.key)
            for id in ids { await terminals.removeValue(forKey: id)?.close() }
            return .init()
        }
        if request.operation == .start {
            if session.phase == .stopped { await store.start(session) }
            guard session.phase == .running else { throw ComputerBridgeError("Computer did not start: \(session.phase.label)") }
            return .init()
        }
        guard session.phase == .running, let runtime = session.container else {
            throw ComputerBridgeError("Computer is stopped. Start it in Noodle Computer or with computer start --computer \(session.id.uuidString).")
        }
        if request.operation.isFileTransfer {
            guard let id = request.transferID, let path = request.path else {
                throw ComputerBridgeError("Missing broker file-transfer reference.")
            }
            let staging = try ComputerTransferFiles.staging(root: transferRoot, id: id, create: false)
            let files = GuestFiles(runtime: runtime)
            var response = ComputerResponse()
            response.path = try GuestFile.normalize(path)
            if request.operation == .fileUpload {
                let fd = try ComputerTransferFiles.openSource(staging)
                let count: Int64
                do { count = try ComputerTransferFiles.size(fd) } catch { Darwin.close(fd); throw error }
                Darwin.close(fd)
                try await files.upload(staging, to: response.path!)
                response.byteCount = count
            } else {
                response.byteCount = try await files.download(response.path!, to: staging)
            }
            return response
        }
        if request.operation == .terminalOpen {
            // Retain completed output, but don't let abandoned sessions grow indefinitely.
            terminals = terminals.filter { !$0.value.exited || Date().timeIntervalSince($0.value.touched) < 600 }
            guard terminals.count < 64, terminals.values.filter({ $0.computerID == session.id && !$0.exited }).count < 16 else {
                throw ComputerBridgeError("Too many terminal sessions. Close an unused session first.")
            }
            let id = UUID(), io = GuestTerminalIO()
            let process = try await runtime.makeProviderTerminal(io: io, id: id)
            guard session.phase == .running, session.container === runtime else {
                try? await process.kill(.kill); try? await process.delete(); io.finish()
                throw ComputerBridgeError("Computer stopped while opening the terminal.")
            }
            terminals[id] = ProviderTerminal(computerID: session.id, owner: owner, io: io, process: process)
            return .init(terminalID: id, offset: 0, exited: false)
        }
        // A web display belongs to the assigned computer, not to an arbitrary PTY.
        if request.operation == .display {
            guard let desktop = session.desktop else { throw ComputerBridgeError("This computer has no web display.") }
            var response = ComputerResponse()
            response.display = .init(url: desktop.url, certificate: desktop.certificate, password: desktop.password, customWeb: desktop.customWeb)
            return response
        }
        if request.operation == .preview {
            // Even a legacy web request with a terminal must not accept another owner's ID.
            if let id = request.terminalID {
                guard let terminal = terminals[id], terminal.owner == owner, terminal.computerID == session.id else {
                    throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
                }
            }
            let view = request.view ?? (request.terminalID != nil ? "terminal" : (session.desktop != nil ? "web" : "terminal"))
            var response = ComputerResponse()
            response.computerID = session.id; response.view = view
            if view == "terminal" {
                let id = try ComputerPresentation.terminal(explicit: request.terminalID,
                    active: terminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }.map(\.key))
                guard let terminal = terminals[id] else { throw ComputerBridgeError("Terminal session is unavailable.") }
                terminal.touched = Date()
                response = terminal.replay.read(from: max(0, terminal.replay.end - 8000))
                response.terminalID = id; response.exited = terminal.exited
                response.computerID = session.id; response.view = view
            } else {
                guard session.desktop != nil else { throw ComputerBridgeError("This computer has no web display.") }
                if let browser = session.browser {
                    response.previewImage = await ComputerPreviewSnapshot.capture(browser.view, desktop: !browser.connection.customWeb) {
                        session.phase == .running && session.browser === browser && browser.failure == nil &&
                        store.sessions.contains(where: { $0 === session })
                    }
                }
            }
            return response
        }
        guard let id = request.terminalID, let terminal = terminals[id], terminal.owner == owner,
              terminal.computerID == session.id else { throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.") }
        terminal.touched = Date()
        switch request.operation {
        case .terminalRead:
            var response = terminal.replay.read(from: request.offset ?? 0)
            response.terminalID = id; response.exited = terminal.exited
            return response
        case .terminalWrite:
            guard !terminal.exited else { throw ComputerBridgeError("This shell has exited. Open a new terminal session.") }
            terminal.io.send(request.data ?? Data())
        case .terminalResize:
            try await terminal.process.resize(to: .init(width: UInt16(request.columns!), height: UInt16(request.rows!)))
        case .terminalClose:
            await terminals.removeValue(forKey: id)?.close()
        default: throw ComputerBridgeError("Unsupported computer operation.")
        }
        return .init()
    }
}

@MainActor private final class ProviderTerminal {
    let computerID: UUID
    let owner: String
    let io: GuestTerminalIO
    let process: LinuxProcess
    var replay = TerminalReplay()
    var exited = false
    var touched = Date()
    private var outputTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    init(computerID: UUID, owner: String, io: GuestTerminalIO, process: LinuxProcess) {
        self.computerID = computerID; self.owner = owner; self.io = io; self.process = process
        outputTask = Task { [weak self] in
            for await data in io.received { self?.replay.append(data) }
        }
        exitTask = Task { [weak self] in
            _ = try? await process.wait()
            self?.exited = true
            try? await process.delete()
            io.finish()
        }
    }
    func close() async {
        exited = true
        try? await process.kill(.kill)
        try? await process.delete()
        io.finish(); outputTask?.cancel(); exitTask?.cancel()
    }
    deinit { outputTask?.cancel(); exitTask?.cancel(); io.finish() }
}
