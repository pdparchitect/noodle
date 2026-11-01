import AppKit
import ComputerBridge
import ComputerCore
import Containerization
import Darwin
import Foundation
import LocalMacCore

/// Computers an agent started and then left running unused. Each is reported once per idle
/// stretch to the app whose agent started it, so the agent can be asked to stop it. Computers
/// a person starts are never reported.
struct ComputerIdleWatch {
    static let running: TimeInterval = 30 * 60, unused: TimeInterval = 15 * 60
    struct Running { var name: String; var watched: Bool }
    private struct Use { var caller: String; var agentID: UUID?; var started: Date; var used: Date; var reported = false }
    private var uses: [UUID: Use] = [:]

    mutating func started(_ computer: UUID, caller: String, agentID: UUID?, at date: Date) {
        uses[computer] = Use(caller: caller, agentID: agentID, started: date, used: date)
    }
    /// Use by anyone counts, and starts a new stretch.
    mutating func used(_ computer: UUID, at date: Date) {
        uses[computer]?.used = date
        uses[computer]?.reported = false
    }
    mutating func stopped(_ computer: UUID) { uses[computer] = nil }
    /// `running` is nil for a computer that is not running; seen so, it is forgotten.
    mutating func due(for caller: String, at now: Date, running: (UUID) -> Running?) -> [ComputerIdleNotice] {
        var due: [ComputerIdleNotice] = []
        for (computer, use) in uses.sorted(by: { $0.value.started < $1.value.started }) {
            guard let state = running(computer) else { uses[computer] = nil; continue }
            if state.watched { used(computer, at: now); continue }
            guard use.caller == caller, !use.reported, now.timeIntervalSince(use.started) >= Self.running,
                  now.timeIntervalSince(use.used) >= Self.unused else { continue }
            uses[computer]?.reported = true
            let minutes = { (since: Date) in Int(now.timeIntervalSince(since) / 60) }
            due.append(ComputerIdleNotice(computerID: computer, agentID: use.agentID, note: "\(state.name) has been running for \(minutes(use.started)) minutes and nothing has used it for \(minutes(use.used)). If you no longer need it, stop it; its files stay."))
        }
        return due
    }
}

/// Agents' shells nobody closes: their bot ended, or lost their IDs when its session restarted or
/// its sign-in expired. Left open they fill the computer's terminal limit. A shell idle at its
/// prompt that no call has used for half an hour is closed; one running a command is kept however
/// long it runs. Where a computer cannot tell whether a command runs, a shell is kept six hours.
/// The person's own terminals, and any on a computer someone is watching, are never closed.
enum AgentTerminalSweep {
    static let idle: TimeInterval = 30 * 60, uncertain: TimeInterval = 6 * 60 * 60

    /// Whether to ask the computer if a command runs in the shell.
    static func suspect(used: Date, person: Bool, watched: Bool, exited: Bool, at now: Date) -> Bool {
        !person && !watched && !exited && now.timeIntervalSince(used) >= idle
    }
    /// `running` is nil where the computer cannot tell.
    static func closes(used: Date, running: Bool?, at now: Date) -> Bool {
        switch running {
        case true?: false
        case false?: now.timeIntervalSince(used) >= idle
        case nil: now.timeIntervalSince(used) >= uncertain
        }
    }
}

@MainActor final class ComputerProvider {
    private weak var store: ComputerStore?
    private var server: ComputerConnectionServer?
    private var terminals: [UUID: ProviderTerminal] = [:]
    private struct LocalTerminal {
        let computer: UUID, owner: String, runtime: LocalMacComputer
        var exited = false
        let opened: Date
        var used: Date
    }
    private var localTerminals: [UUID: LocalTerminal] = [:]
    private var windowsTerminals: [UUID: WindowsProviderTerminal] = [:]
    private var sshTerminals: [UUID: SSHProviderTerminal] = [:]
    /// Where a person watching remotely types and clicks, one per desktop view.
    /// Live views of displays and terminals. While one is watched, bots are kept off its computer.
    private var surfaces: [String: (computer: UUID, streamer: SurfaceStreamer)] = [:]
    private let transferRoot: URL
    private var idle = ComputerIdleWatch()
    private var sweeper: Task<Void, Never>?
    var now: () -> Date = Date.init

    /// `listens` false answers only what `handle` is given, as in tests, which cannot sign a socket.
    init(store: ComputerStore, socket: URL? = nil, listens: Bool = true) throws {
        self.store = store
        let endpoint = try socket ?? ComputerConnection.socketURL()
        transferRoot = endpoint.deletingLastPathComponent()
        guard listens else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard let self else { return }
                await self.sweepTerminals()
            }
        }
        let clients = socket == nil ? ComputerConnection.clientIDs : ComputerConnection.clientIDs + ["com.pdparchitect.noodle.integration"]
        server = try ComputerConnectionServer(socket: endpoint, team: ComputerConnection.signingTeam(), clientIDs: clients, handler: {
            [weak self] request, peer in
            guard let self else { return .init(error: "Computer is closing.") }
            return await self.respond(request, peer: peer)
        }, surface: { [weak self] request, peer, socket in
            guard let self else { return .init(error: "Computer is closing.") }
            return await self.respond(request, peer: peer, surface: socket)
        })
    }
    private func respond(_ request: ComputerRequest, peer: String, surface: SurfaceSocket? = nil) async -> ComputerResponse {
        do { return try await handle(request, peer: peer, surface: surface) }
        catch { return .init(error: error.localizedDescription) }
    }
    /// Watches a computer an agent started, for the app the agent works through.
    func started(_ session: ComputerSession, peer: String, agentID: UUID?) {
        idle.started(session.id, caller: ComputerBuildIdentity.principal(for: peer), agentID: agentID, at: now())
    }
    /// What the app at `peer` is told once: computers its agents started and then left unused.
    func idleNotices(for peer: String) -> [ComputerIdleNotice] {
        idle.due(for: ComputerBuildIdentity.principal(for: peer), at: now()) { id in
            guard let session = store?.sessions.first(where: { $0.id == id }), session.phase == .running else { return nil }
            return .init(name: session.computer.name, watched: isWatched(id))
        }
    }
    /// `stagingRoot` is where file transfers wait, when not beside the companion socket.
    func handle(_ request: ComputerRequest, peer: String, surface socket: SurfaceSocket? = nil, stagingRoot: URL? = nil) async throws -> ComputerResponse {
        guard let store else { throw ComputerBridgeError("Computer is closing.") }
        let owner = ComputerBuildIdentity.principal(for: peer) + ":" + (request.agentID?.uuidString ?? "human")
        if request.operation == .terminalResolve {
            if let id = request.terminalID, let terminal = windowsTerminals[id], terminal.owner == owner {
                var response = ComputerResponse(); response.computerID = terminal.computerID; return response
            }
            if let id = request.terminalID, let terminal = sshTerminals[id], terminal.owner == owner {
                var response = ComputerResponse(); response.computerID = terminal.computerID; return response
            }
            if let id = request.terminalID, let terminal = localTerminals[id], terminal.owner == owner,
               store.sessions.contains(where: { $0.id == terminal.computer && $0.localMac === terminal.runtime && $0.phase == .running }) {
                var response = ComputerResponse(); response.computerID = terminal.computer; return response
            }
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
            var response = ComputerResponse(computers: store.sessions.filter { Self.served($0.computer.kind) }.map(Self.remote))
            response.capabilities = ComputerCapabilities()
            return response
        }
        if request.operation == .idle {
            var response = ComputerResponse()
            response.idle = idleNotices(for: peer)
            return response
        }
        if request.operation == .templates {
            var response = ComputerResponse()
            response.templates = ContainerRegistry.bundled.templates.map {
                ComputerTemplateSummary(id: $0.id, name: $0.name, description: $0.description, symbol: $0.symbol)
            }
            return response
        }
        if request.operation == .create, let draft = request.computer {
            // Only containers: a client never makes a computer out of this Mac itself.
            guard let template = ContainerRegistry.bundled.templates.first(where: { $0.id == draft.template }) else {
                throw ComputerBridgeError("\(ComputerAppIdentity.name) does not offer that kind of computer.")
            }
            guard store.creationStatus == nil else {
                throw ComputerBridgeError("\(ComputerAppIdentity.name) is making another computer. Try again when it finishes.")
            }
            var computer = template.makeComputer(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
            computer.description = draft.description
            var appearance = ComputerAppearance()
            appearance.iconSymbol = draft.symbol
            appearance.iconColour = draft.colour ?? 0
            computer.appearance = appearance
            try computer.validate()
            guard await store.create(computer, source: nil, selects: false), let session = store.sessions.first(where: { $0.id == computer.id }) else {
                let message = store.creationWasCancelled ? "Making the computer was cancelled." : store.error ?? "The computer could not be made."
                store.error = nil
                throw ComputerBridgeError(message)
            }
            store.note(session, usedBy: peer)
            return ComputerResponse(computers: [Self.remote(session)])
        }
        guard let session = store.sessions.first(where: { $0.id == request.computerID }), Self.served(session.computer.kind) else {
            throw ComputerBridgeError("This computer no longer exists or is not supported by this provider version.")
        }
        store.note(session, usedBy: peer)
        // Bots name themselves; apps outside Noodle are agents too. A person's start is not watched.
        let agentStarts = request.operation == .start && session.phase.canStart
            && (request.agentID != nil || ComputerExternalService.isPeer(peer))
        defer { if agentStarts, session.phase == .running { started(session, peer: peer, agentID: request.agentID) } }
        if ![.start, .stop, .setOwner, .update, .revoke].contains(request.operation) { idle.used(session.id, at: now()) }
        if request.operation == .setOwner {
            try store.setHubOwner(session, request.owner.map { HubOwner(id: $0.id, name: $0.name) }, from: peer)
            return .init()
        }
        if request.operation == .update, let draft = request.computer {
            var appearance = session.computer.appearance ?? ComputerAppearance()
            if let symbol = draft.symbol { appearance.iconSymbol = symbol }
            if let colour = draft.colour { appearance.iconColour = colour }
            // An error already showing in the window is not this edit's.
            let shown = store.error
            store.error = nil
            store.rename(session, name: draft.name, description: draft.description, appearance: appearance)
            let failure = store.error
            store.error = shown
            if let failure { throw ComputerBridgeError(failure) }
            return ComputerResponse(computers: [Self.remote(session)])
        }
        if request.operation == .delete {
            // Only containers: this Mac itself is set up and removed in Noodle Computer.
            guard session.computer.kind == .container else {
                throw ComputerBridgeError("Remove this computer in \(ComputerAppIdentity.name).")
            }
            if session.phase != .stopped { await store.stop(session) }
            guard session.canDelete else { throw ComputerBridgeError("Stop this computer before deleting it.") }
            let shown = store.error
            store.error = nil
            store.remove(session)
            let failure = store.error
            store.error = shown
            if let failure { throw ComputerBridgeError(failure) }
            return .init()
        }
        if request.operation == .stop {
            // A person using the computer live keeps it running until they close the view.
            if isWatched(session.id) { throw ComputerBridgeError("A person is using this computer right now. Try again when they're done.") }
            if session.phase != .stopped { await store.stop(session) }
            if case .failed(let message) = session.phase { throw ComputerBridgeError(message) }
            if session.phase == .stopped { idle.stopped(session.id) }
            return ComputerResponse(computers: [Self.remote(session)])
        }
        if session.computer.kind == .localMac { return try await handleLocal(request, session: session, store: store, owner: owner, socket: socket, stagingRoot: stagingRoot) }
        if session.computer.kind == .windows { return try await handleWindows(request, session: session, store: store, owner: owner, stagingRoot: stagingRoot) }
        if session.computer.kind == .ssh { return try await handleSSH(request, session: session, store: store, owner: owner, socket: socket, stagingRoot: stagingRoot) }
        if request.operation == .revoke {
            let ids = terminals.filter { $0.value.owner == owner && $0.value.computerID == session.id }.map(\.key)
            for id in ids { await terminals.removeValue(forKey: id)?.close() }
            return .init()
        }
        // A person opening a stopped computer wakes it, as a bot starting it does.
        if request.operation == .start || request.operation == .surfaceStream {
            if session.phase.canStart { await store.start(session) }
        }
        if request.operation == .start {
            guard session.phase == .running else { throw ComputerBridgeError(session.phase.startFailureDescription) }
            return .init()
        }
        guard session.phase == .running, let runtime = session.container else {
            throw ComputerBridgeError("Computer is stopped. Start it in \(ComputerAppIdentity.name) or with computer start --computer \(session.id.uuidString).")
        }
        if request.operation == .surfaceStream {
            guard let socket else { throw ComputerBridgeError("A live view needs a connection of its own.") }
            try await surface(request, session: session, runtime: runtime, owner: owner, socket: socket)
            return .init()
        }
        // A person using the computer live has it to themselves until they close the view.
        if [.terminalOpen, .terminalWrite, .terminalResize, .fileUpload, .fileDownload].contains(request.operation), isWatched(session.id) {
            throw ComputerBridgeError("A person is using this computer right now. Try again when they're done.")
        }
        if request.operation.isFileTransfer {
            guard let id = request.transferID, let path = request.path else {
                throw ComputerBridgeError("Missing broker file-transfer reference.")
            }
            let staging = try ComputerTransferFiles.staging(root: stagingRoot ?? transferRoot, id: id, create: false)
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
            return .init(terminalID: try await openTerminal(on: session, runtime: runtime, owner: owner, person: false), offset: 0, exited: false)
        }
        if request.operation == .terminalList {
            var listed: [RemoteTerminal] = []
            for (id, terminal) in terminals.filter({ $0.value.owner == owner && $0.value.computerID == session.id }).sorted(by: { $0.value.opened < $1.value.opened }) {
                var running: Bool?
                if !terminal.exited { running = await runtime.providerTerminalRunsCommand(id) }
                listed.append(summary(id, opened: terminal.opened, used: terminal.touched, running: running, exited: terminal.exited))
            }
            var response = ComputerResponse()
            response.terminals = listed
            return response
        }
        if request.operation == .preview {
            // Even a legacy web request with a terminal must not accept another owner's ID.
            if let id = request.terminalID {
                guard let terminal = terminals[id], terminal.owner == owner, terminal.computerID == session.id else {
                    throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
                }
            }
            let view = request.view ?? (request.terminalID != nil ? "terminal" : (session.display != nil ? "web" : "terminal"))
            var response = ComputerResponse()
            response.computerID = session.id; response.view = view
            if view == "terminal" {
                let id = try ComputerPresentation.terminal(explicit: request.terminalID,
                    active: terminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }.map(\.key))
                guard let terminal = terminals[id] else { throw ComputerBridgeError("Terminal session is unavailable.") }
                terminal.touched = now()
                response = terminal.replay.read(from: max(0, terminal.replay.end - 8000))
                response.terminalID = id; response.exited = terminal.exited
                response.computerID = session.id; response.view = view
            } else {
                guard let display = session.display else { throw ComputerBridgeError("This computer has no display.") }
                response.previewImage = await ComputerPreviewSnapshot.capture(valid: {
                    session.phase == .running && session.display === display && store.sessions.contains(where: { $0 === session })
                }) { try await display.surface.frame().image }
            }
            return response
        }
        guard let id = request.terminalID, let terminal = terminals[id], terminal.owner == owner,
              terminal.computerID == session.id else { throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.") }
        terminal.touched = now()
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
    /// A person watching a running computer: its desktop if it has one, else the terminal the card shows.
    /// `person` for the person's own terminal, which is never closed for being idle.
    private func openTerminal(on session: ComputerSession, runtime: ContainerComputer, owner: String, person: Bool) async throws -> UUID {
        await sweepTerminals()
        guard terminals.count < 64, terminals.values.filter({ $0.computerID == session.id && !$0.exited }).count < 16 else {
            throw ComputerBridgeError("Too many terminal sessions. Close an unused session first.")
        }
        let id = UUID(), io = GuestTerminalIO()
        let process = try await runtime.makeProviderTerminal(io: io, id: id)
        guard session.phase == .running, session.container === runtime else {
            try? await process.kill(.kill); try? await process.delete(); io.finish()
            throw ComputerBridgeError("Computer stopped while opening the terminal.")
        }
        terminals[id] = ProviderTerminal(computerID: session.id, owner: owner, person: person, opened: now(), io: io, process: process)
        return id
    }

    /// Closes agents' shells left idle at their prompt, as `AgentTerminalSweep` decides, and
    /// forgets shells that exited ten minutes ago.
    func sweepTerminals() async {
        guard let store else { return }
        let forgotten = now().addingTimeInterval(-600)
        terminals = terminals.filter { !$0.value.exited || $0.value.touched > forgotten }
        for (id, terminal) in terminals where AgentTerminalSweep.suspect(used: terminal.touched, person: terminal.person,
                                                                           watched: isWatched(terminal.computerID), exited: terminal.exited, at: now()) {
            guard let runtime = store.sessions.first(where: { $0.id == terminal.computerID })?.container else { continue }
            let running = await runtime.providerTerminalRunsCommand(id)
            guard terminals[id] === terminal, !isWatched(terminal.computerID),
                  AgentTerminalSweep.closes(used: terminal.touched, running: running, at: now()) else { continue }
            await terminals.removeValue(forKey: id)?.close()
        }
        for (id, terminal) in localTerminals where terminal.exited && terminal.used <= forgotten {
            localTerminals.removeValue(forKey: id)
            var close = LocalMacRequest(.terminalClose); close.terminalID = id
            _ = try? await terminal.runtime.call(close)
        }
        for (id, terminal) in localTerminals where AgentTerminalSweep.suspect(used: terminal.used, person: false,
                                                                                watched: isWatched(terminal.computer), exited: terminal.exited, at: now()) {
            let state = await localState(id, runtime: terminal.runtime)
            guard let current = localTerminals[id], current.runtime === terminal.runtime else { continue }
            if state.exited { localTerminals[id]?.exited = true; continue }
            guard AgentTerminalSweep.closes(used: current.used, running: state.running, at: now()) else { continue }
            localTerminals.removeValue(forKey: id)
            var close = LocalMacRequest(.terminalClose); close.terminalID = id
            _ = try? await terminal.runtime.call(close)
        }
        // Neither an SSH server nor the Windows agent says whether a command runs in a shell.
        for (id, terminal) in sshTerminals where (terminal.exited && terminal.touched <= forgotten)
            || (AgentTerminalSweep.suspect(used: terminal.touched, person: terminal.person, watched: isWatched(terminal.computerID), exited: terminal.exited, at: now())
                && AgentTerminalSweep.closes(used: terminal.touched, running: nil, at: now())) {
            sshTerminals.removeValue(forKey: id)?.close()
        }
        for (id, terminal) in windowsTerminals where (terminal.exited && terminal.touched <= forgotten)
            || (AgentTerminalSweep.suspect(used: terminal.touched, person: false, watched: isWatched(terminal.computerID), exited: terminal.exited, at: now())
                && AgentTerminalSweep.closes(used: terminal.touched, running: nil, at: now())) {
            windowsTerminals.removeValue(forKey: id)?.close()
        }
    }

    /// Whether a command runs in a Local Mac shell and whether it has exited, without reading its
    /// output. Nil `running` from a helper older than this question, or one that cannot answer.
    private func localState(_ id: UUID, runtime: LocalMacComputer) async -> (running: Bool?, exited: Bool) {
        var read = LocalMacRequest(.terminalRead); read.terminalID = id; read.offset = .max
        guard let reply = try? await runtime.call(read) else { return (nil, false) }
        return reply.exited == true ? (false, true) : (reply.running, false)
    }

    private func summary(_ id: UUID, opened: Date, used: Date, running: Bool?, exited: Bool) -> RemoteTerminal {
        RemoteTerminal(id: id, opened: opened, used: used, running: exited ? false : running, exited: exited)
    }

    private func surface(_ request: ComputerRequest, session: ComputerSession, runtime: ContainerComputer, owner: String,
                         socket: SurfaceSocket) async throws {
        if let display = session.display {
            // The guest serves its own screen: the Mac's view of it cannot be captured.
            streamer("display:\(session.id)", computer: session.id, capture: {
                try await display.surface.frame()
            }, apply: { input in
                try await display.surface.send(input)
            }).attach(socket)
            return
        }
        // The terminal the card showed, else another of the bot's, else a new one: a terminal does
        // not outlive a restart.
        let open = terminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }
        let id: UUID
        if let shown = request.terminalID, open[shown] != nil { id = shown }
        else if let other = open.max(by: { $0.value.touched < $1.value.touched })?.key { id = other }
        else { id = try await openTerminal(on: session, runtime: runtime, owner: owner, person: request.agentID == nil) }
        guard let terminal = terminals[id] else { throw ComputerBridgeError("The terminal is closed.") }
        streamer("terminal:\(id)", computer: session.id, capture: { [weak terminal] in
            terminal.flatMap { TerminalSurface.picture($0.replay.read(from: max(0, $0.replay.end - 16_000)).data ?? Data()) }
        }, apply: { [weak terminal] input in
            guard let terminal, !terminal.exited, let bytes = TerminalSurface.bytes(for: input) else { return }
            terminal.touched = Date()
            terminal.io.send(bytes)
        }).attach(socket)
    }

    private func streamer(_ key: String, computer: UUID,
                          capture: @escaping @MainActor () async throws -> (image: CGImage, size: CGSize)?,
                          apply: @escaping @MainActor (SurfaceInput) async throws -> Void) -> SurfaceStreamer {
        if let existing = surfaces[key] { return existing.streamer }
        let streamer = SurfaceStreamer(capture: capture, apply: apply)
        surfaces[key] = (computer, streamer)
        return streamer
    }

    /// Someone is watching the computer live.
    private func isWatched(_ computer: UUID) -> Bool {
        surfaces.values.contains { $0.computer == computer && $0.streamer.isWatched }
    }

    /// Windows needs macOS 27; on older systems its computers are not offered to clients.
    static func served(_ kind: ComputerKind) -> Bool {
        if kind == .windows, #unavailable(macOS 27) { return false }
        return kind == .container || kind == .localMac || kind == .windows || kind == .ssh
    }

    private static func remote(_ session: ComputerSession) -> RemoteComputer {
        let appearance = session.computer.appearance
        let icon = appearance?.iconImage
        return RemoteComputer(id: session.id, name: session.computer.name, description: session.computer.description, kind: session.computer.displayType,
            state: session.phase.label, symbol: appearance?.iconSymbol ?? session.computer.displaySymbol,
            colour: appearance?.iconColour ?? 0, icon: (icon?.count ?? 0) <= 65_536 ? icon : nil,
            hasWebDisplay: session.display != nil || session.computer.kind == .localMac,
            owner: session.computer.hubOwner.map { ComputerOwner(id: $0.id, name: $0.name) })
    }
    /// Terminals are PowerShell consoles through the Windows agent; files go through the same service as the
    /// Files view. Clients see the screen in previews but do not control the desktop.
    private func handleWindows(_ request: ComputerRequest, session: ComputerSession, store: ComputerStore, owner: String, stagingRoot: URL?) async throws -> ComputerResponse {
        guard #available(macOS 27, *) else { throw ComputerBridgeError("Windows computers need macOS 27.") }
        windowsTerminals = windowsTerminals.filter { _, terminal in
            store.sessions.contains { $0.id == terminal.computerID && $0.windows?.agent === terminal.agent && $0.phase == .running }
        }
        if request.operation == .delete { throw ComputerBridgeError("Remove this computer in \(ComputerAppIdentity.name).") }
        if request.operation == .revoke {
            for (id, terminal) in windowsTerminals where terminal.owner == owner && terminal.computerID == session.id {
                windowsTerminals.removeValue(forKey: id)?.close()
            }
            return .init()
        }
        if request.operation == .start {
            if session.phase.canStart { await store.start(session) }
            guard session.phase == .running else { throw ComputerBridgeError(session.phase.startFailureDescription) }
            return .init()
        }
        guard session.phase == .running, let windows = session.windows else {
            throw ComputerBridgeError("Computer is stopped. Start it in \(ComputerAppIdentity.name) or with computer start --computer \(session.id.uuidString).")
        }
        guard windows.agentConnected else { throw ComputerBridgeError("Windows is still starting. Try again in a minute.") }
        if request.operation.isFileTransfer {
            guard let id = request.transferID, let path = request.path else { throw ComputerBridgeError("Missing broker file-transfer reference.") }
            let staging = try ComputerTransferFiles.staging(root: stagingRoot ?? transferRoot, id: id, create: false)
            let files = WindowsFileService { [weak windows] in windows?.agent }
            var reply = ComputerResponse(); reply.path = try GuestFile.normalize(path)
            if request.operation == .fileUpload {
                let fd = try ComputerTransferFiles.openSource(staging)
                let count: Int64
                do { count = try ComputerTransferFiles.size(fd) } catch { Darwin.close(fd); throw error }
                Darwin.close(fd)
                try await files.upload(staging, to: reply.path!, progress: { _ in })
                reply.byteCount = count
            } else { reply.byteCount = try await files.download(reply.path!, to: staging) }
            return reply
        }
        if request.operation == .terminalOpen {
            await sweepTerminals()
            guard windowsTerminals.count < 64, windowsTerminals.values.filter({ $0.computerID == session.id && !$0.exited }).count < 16 else {
                throw ComputerBridgeError("Too many terminal sessions. Close an unused session first.")
            }
            guard session.windows === windows, session.phase == .running else { throw ComputerBridgeError("The computer stopped while opening its terminal.") }
            let id = UUID()
            windowsTerminals[id] = WindowsProviderTerminal(computerID: session.id, owner: owner, agent: windows.agent, at: now())
            return .init(terminalID: id, offset: 0, exited: false)
        }
        if request.operation == .terminalList {
            var reply = ComputerResponse()
            reply.terminals = windowsTerminals.filter { $0.value.owner == owner && $0.value.computerID == session.id }
                .sorted { $0.value.opened < $1.value.opened }
                .map { summary($0.key, opened: $0.value.opened, used: $0.value.touched, running: nil, exited: $0.value.exited) }
            return reply
        }
        if request.operation == .preview {
            let view = request.view ?? (request.terminalID == nil ? "web" : "terminal")
            var reply = ComputerResponse(); reply.computerID = session.id; reply.view = view
            if view == "terminal" {
                let id = try ComputerPresentation.terminal(explicit: request.terminalID,
                    active: windowsTerminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }.map(\.key))
                guard let terminal = windowsTerminals[id], terminal.owner == owner else { throw ComputerBridgeError("Terminal session is unavailable.") }
                terminal.touched = now()
                reply = terminal.replay.read(from: max(0, terminal.replay.end - 8000))
                reply.terminalID = id; reply.exited = terminal.exited; reply.computerID = session.id; reply.view = view
            } else {
                reply.previewImage = await ComputerPreviewSnapshot.capture(valid: { session.windows === windows && session.phase == .running }) {
                    guard let frame = windows.lastFrame else { throw ComputerBridgeError("Windows has not drawn its screen yet.") }
                    return frame
                }
            }
            return reply
        }
        guard let id = request.terminalID, let terminal = windowsTerminals[id], terminal.owner == owner, terminal.computerID == session.id else {
            throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
        }
        terminal.touched = now()
        switch request.operation {
        case .terminalRead:
            var reply = terminal.replay.read(from: request.offset ?? 0)
            reply.terminalID = id; reply.exited = terminal.exited
            return reply
        case .terminalWrite:
            guard !terminal.exited else { throw ComputerBridgeError("This shell has exited. Open a new terminal session.") }
            terminal.write(request.data ?? Data())
        case .terminalResize: terminal.resize(columns: request.columns ?? 120, rows: request.rows ?? 30)
        case .terminalClose: windowsTerminals.removeValue(forKey: id)?.close()
        default: throw ComputerBridgeError("Unsupported computer operation.")
        }
        return .init()
    }

    /// Shells on the server, each its own SSH channel; files go through the same service as the Files view.
    /// There is no screen, so a live view shows a terminal, as for a shell container.
    private func handleSSH(_ request: ComputerRequest, session: ComputerSession, store: ComputerStore, owner: String,
                           socket: SurfaceSocket?, stagingRoot: URL?) async throws -> ComputerResponse {
        sshTerminals = sshTerminals.filter { _, terminal in
            store.sessions.contains { $0.id == terminal.computerID && $0.sshRuntime?.connection === terminal.connection && $0.phase == .running }
                && (!terminal.exited || now().timeIntervalSince(terminal.touched) < 600)
        }
        if request.operation == .delete { throw ComputerBridgeError("Remove this computer in \(ComputerAppIdentity.name).") }
        if request.operation == .revoke {
            for (id, terminal) in sshTerminals where terminal.owner == owner && terminal.computerID == session.id {
                sshTerminals.removeValue(forKey: id)?.close()
            }
            return .init()
        }
        if request.operation == .start || request.operation == .surfaceStream {
            if session.phase.canStart { await store.start(session) }
        }
        if request.operation == .start {
            guard session.phase == .running else { throw ComputerBridgeError(session.phase.startFailureDescription) }
            return .init()
        }
        guard session.phase == .running, let runtime = session.sshRuntime else {
            throw ComputerBridgeError("Computer is stopped. Start it in \(ComputerAppIdentity.name) or with computer start --computer \(session.id.uuidString).")
        }
        // `person` for the person's own terminal, which is never closed for being idle.
        func open(person: Bool) async throws -> UUID {
            await sweepTerminals()
            guard sshTerminals.count < 64, sshTerminals.values.filter({ $0.computerID == session.id && !$0.exited }).count < 16 else {
                throw ComputerBridgeError("Too many terminal sessions. Close an unused session first.")
            }
            let terminal = try await SSHProviderTerminal.open(computerID: session.id, owner: owner, connection: runtime.connection)
            guard session.sshRuntime === runtime, session.phase == .running else {
                terminal.close()
                throw ComputerBridgeError("The computer stopped while opening its terminal.")
            }
            terminal.person = person; terminal.opened = now(); terminal.touched = terminal.opened
            let id = UUID()
            sshTerminals[id] = terminal
            return id
        }
        if request.operation == .surfaceStream {
            guard let socket else { throw ComputerBridgeError("A live view needs a connection of its own.") }
            let shown = sshTerminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }
            let id: UUID
            if let requested = request.terminalID, shown[requested] != nil { id = requested }
            else if let other = shown.max(by: { $0.value.touched < $1.value.touched })?.key { id = other }
            else { id = try await open(person: request.agentID == nil) }
            guard let terminal = sshTerminals[id] else { throw ComputerBridgeError("The terminal is closed.") }
            streamer("terminal:\(id)", computer: session.id, capture: { [weak terminal] in
                terminal.flatMap { TerminalSurface.picture($0.replay.read(from: max(0, $0.replay.end - 16_000)).data ?? Data()) }
            }, apply: { [weak terminal] input in
                guard let terminal, !terminal.exited, let bytes = TerminalSurface.bytes(for: input) else { return }
                terminal.touched = Date()
                terminal.write(bytes)
            }).attach(socket)
            return .init()
        }
        if [.terminalOpen, .terminalWrite, .terminalResize, .fileUpload, .fileDownload].contains(request.operation), isWatched(session.id) {
            throw ComputerBridgeError("A person is using this computer right now. Try again when they're done.")
        }
        if request.operation.isFileTransfer {
            guard let id = request.transferID, let path = request.path else { throw ComputerBridgeError("Missing broker file-transfer reference.") }
            let staging = try ComputerTransferFiles.staging(root: stagingRoot ?? transferRoot, id: id, create: false)
            let files = SSHFileService(connection: runtime.connection)
            defer { Task { await files.close() } }
            var reply = ComputerResponse(); reply.path = try GuestFile.normalize(path)
            if request.operation == .fileUpload {
                let fd = try ComputerTransferFiles.openSource(staging)
                let count: Int64
                do { count = try ComputerTransferFiles.size(fd) } catch { Darwin.close(fd); throw error }
                Darwin.close(fd)
                try await files.upload(staging, to: reply.path!, progress: { _ in })
                reply.byteCount = count
            } else { reply.byteCount = try await files.download(reply.path!, to: staging) }
            return reply
        }
        if request.operation == .terminalOpen { return .init(terminalID: try await open(person: false), offset: 0, exited: false) }
        if request.operation == .terminalList {
            var reply = ComputerResponse()
            reply.terminals = sshTerminals.filter { $0.value.owner == owner && $0.value.computerID == session.id }
                .sorted { $0.value.opened < $1.value.opened }
                .map { summary($0.key, opened: $0.value.opened, used: $0.value.touched, running: nil, exited: $0.value.exited) }
            return reply
        }
        if request.operation == .preview {
            var reply = ComputerResponse(); reply.computerID = session.id; reply.view = "terminal"
            let id = try ComputerPresentation.terminal(explicit: request.terminalID,
                active: sshTerminals.filter { $0.value.owner == owner && $0.value.computerID == session.id && !$0.value.exited }.map(\.key))
            guard let terminal = sshTerminals[id], terminal.owner == owner, terminal.computerID == session.id else {
                throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
            }
            terminal.touched = now()
            reply = terminal.replay.read(from: max(0, terminal.replay.end - 8000))
            reply.terminalID = id; reply.exited = terminal.exited; reply.computerID = session.id; reply.view = "terminal"
            return reply
        }
        guard let id = request.terminalID, let terminal = sshTerminals[id], terminal.owner == owner, terminal.computerID == session.id else {
            throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
        }
        terminal.touched = now()
        switch request.operation {
        case .terminalRead:
            var reply = terminal.replay.read(from: request.offset ?? 0)
            reply.terminalID = id; reply.exited = terminal.exited
            return reply
        case .terminalWrite:
            guard !terminal.exited else { throw ComputerBridgeError("This shell has exited. Open a new terminal session.") }
            terminal.write(request.data ?? Data())
        case .terminalResize: terminal.resize(columns: request.columns ?? 120, rows: request.rows ?? 30)
        case .terminalClose: sshTerminals.removeValue(forKey: id)?.close()
        default: throw ComputerBridgeError("Unsupported computer operation.")
        }
        return .init()
    }

    private func handleLocal(_ request: ComputerRequest, session: ComputerSession, store: ComputerStore, owner: String,
                             socket: SurfaceSocket?, stagingRoot: URL?) async throws -> ComputerResponse {
        localTerminals = localTerminals.filter { _, value in
            store.sessions.contains { $0.id == value.computer && $0.localMac === value.runtime && $0.phase == .running }
        }
        if request.operation == .revoke {
            for (id, terminal) in localTerminals where terminal.owner == owner && terminal.computer == session.id {
                localTerminals.removeValue(forKey: id)
                var close = LocalMacRequest(.terminalClose); close.terminalID = id
                _ = try? await terminal.runtime.call(close)
            }
            return .init()
        }
        if request.operation == .start || request.operation == .surfaceStream {
            if session.phase.canStart { await store.start(session) }
        }
        if request.operation == .start {
            guard session.phase == .running else { throw ComputerBridgeError(session.phase.startFailureDescription) }
            return .init()
        }
        guard session.phase == .running, let runtime = session.localMac else { throw ComputerBridgeError("Start this Local Mac in \(ComputerAppIdentity.name).") }
        if request.operation == .surfaceStream {
            guard let socket else { throw ComputerBridgeError("A live view needs a connection of its own.") }
            // Keyed by connection: a restarted Local Mac gets a new desktop, so a new streamer.
            streamer("desktop:\(session.id):\(ObjectIdentifier(runtime).hashValue)", computer: session.id, capture: { [weak runtime] in
                runtime?.image.flatMap(LocalMacLiveView.picture)
            }, apply: { [weak runtime] input in
                guard let runtime, let size = runtime.image?.size else { return }
                LocalMacLiveView.events(for: input, size: size).forEach(runtime.send)
            }).attach(socket)
            return .init()
        }
        func terminal(_ id: UUID?) throws -> UUID {
            guard let id, let value = localTerminals[id], value.owner == owner, value.computer == session.id, value.runtime === runtime else {
                throw ComputerBridgeError("Terminal session is unavailable or belongs to another agent.")
            }
            return id
        }
        if request.operation.isFileTransfer {
            guard let id = request.transferID, let path = request.path else { throw ComputerBridgeError("Missing broker file-transfer reference.") }
            let staging = try ComputerTransferFiles.staging(root: stagingRoot ?? transferRoot, id: id, create: false)
            var reply = ComputerResponse(); reply.path = path
            if request.operation == .fileUpload {
                let fd = try ComputerTransferFiles.openSource(staging); Darwin.close(fd)
                reply.byteCount = try await runtime.upload(staging, to: path)
            } else { reply.byteCount = try await runtime.download(path, to: staging) }
            return reply
        }
        if request.operation == .terminalOpen {
            // Agents' shells only: the person's own terminal opens however many agents hold.
            await sweepTerminals()
            guard localTerminals.count < 64, localTerminals.values.filter({ $0.computer == session.id && !$0.exited }).count < 16 else {
                throw ComputerBridgeError("Too many terminal sessions. Close an unused session first.")
            }
            let reply = try await runtime.call(.init(.terminalOpen))
            guard let id = reply.terminalID, session.localMac === runtime, session.phase == .running else { throw ComputerBridgeError("The computer stopped while opening its terminal.") }
            localTerminals[id] = LocalTerminal(computer: session.id, owner: owner, runtime: runtime, opened: now(), used: now())
            return .init(terminalID: id, offset: 0, exited: false)
        }
        if request.operation == .terminalList {
            var listed: [RemoteTerminal] = []
            for (id, terminal) in localTerminals.filter({ $0.value.owner == owner && $0.value.computer == session.id }).sorted(by: { $0.value.opened < $1.value.opened }) {
                var state: (running: Bool?, exited: Bool) = (false, true)
                if !terminal.exited { state = await localState(id, runtime: runtime) }
                if state.exited { localTerminals[id]?.exited = true }
                listed.append(summary(id, opened: terminal.opened, used: terminal.used, running: state.running, exited: state.exited))
            }
            var reply = ComputerResponse()
            reply.terminals = listed
            return reply
        }
        if request.operation == .preview {
            if let id = request.terminalID { _ = try terminal(id); localTerminals[id]?.used = now() }
            let view = request.view ?? (request.terminalID == nil ? "web" : "terminal")
            var reply = ComputerResponse(); reply.computerID = session.id; reply.view = view
            if view == "web" {
                let frame = try await runtime.call(.init(.screenshot))
                reply.previewImage = frame.data
            } else {
                let id = try ComputerPresentation.terminal(explicit: request.terminalID,
                    active: localTerminals.filter { $0.value.owner == owner && $0.value.computer == session.id }.map(\.key))
                var read = LocalMacRequest(.terminalRead); read.terminalID = id; read.offset = 0
                let result = try await runtime.call(read)
                reply.terminalID = id; reply.data = result.data; reply.offset = result.offset; reply.exited = result.exited
            }
            return reply
        }
        let id = try terminal(request.terminalID)
        localTerminals[id]?.used = now()
        let operation: LocalMacOperation
        switch request.operation {
        case .terminalRead: operation = .terminalRead
        case .terminalWrite: operation = .terminalWrite
        case .terminalResize: operation = .terminalResize
        case .terminalClose: operation = .terminalClose
        default: throw ComputerBridgeError("Unsupported Local Mac operation.")
        }
        var command = LocalMacRequest(operation); command.terminalID = id; command.offset = request.offset
        command.data = request.data; command.width = request.columns; command.height = request.rows
        let result = try await runtime.call(command)
        if operation == .terminalClose { localTerminals.removeValue(forKey: id) }
        else if result.exited == true { localTerminals[id]?.exited = true }
        return .init(terminalID: id, data: result.data, offset: result.offset, exited: result.exited)
    }
}

/// A client's PowerShell console in Windows, with its output kept for reading back.
@MainActor private final class WindowsProviderTerminal {
    let computerID: UUID
    let owner: String
    let agent: WindowsAgent
    private let channel: UInt32
    var replay = TerminalReplay()
    var exited = false
    let opened: Date
    var touched: Date
    init(computerID: UUID, owner: String, agent: WindowsAgent, at date: Date) {
        self.computerID = computerID; self.owner = owner; self.agent = agent; opened = date; touched = date
        var number: UInt32 = 0
        weak var weakSelf: WindowsProviderTerminal?
        number = agent.open { frame in
            Task { @MainActor in
                switch frame.type {
                case 101: weakSelf?.replay.append(frame.payload)
                case 102, 111: weakSelf?.exited = true
                default: break
                }
            }
        }
        channel = number
        weakSelf = self
        let request: [String: Any] = ["cmd": "powershell.exe -NoLogo", "pty": true, "cols": 120, "rows": 30]
        agent.send(1, channel: channel, payload: (try? JSONSerialization.data(withJSONObject: request)) ?? Data())
    }
    func write(_ data: Data) { agent.send(2, channel: channel, payload: data) }
    func resize(columns: Int, rows: Int) {
        var size = Data()
        withUnsafeBytes(of: Int16(clamping: columns).littleEndian) { size.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(clamping: rows).littleEndian) { size.append(contentsOf: $0) }
        agent.send(3, channel: channel, payload: size)
    }
    func close() {
        exited = true
        agent.send(5, channel: channel)
        agent.close(channel)
    }
}

@MainActor private final class ProviderTerminal {
    let computerID: UUID
    let owner: String
    /// The person's own terminal, never closed for being idle.
    let person: Bool
    let opened: Date
    let io: GuestTerminalIO
    let process: LinuxProcess
    var replay = TerminalReplay()
    var exited = false
    var touched: Date
    private var outputTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    init(computerID: UUID, owner: String, person: Bool, opened: Date, io: GuestTerminalIO, process: LinuxProcess) {
        self.computerID = computerID; self.owner = owner; self.person = person; self.opened = opened; touched = opened
        self.io = io; self.process = process
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
