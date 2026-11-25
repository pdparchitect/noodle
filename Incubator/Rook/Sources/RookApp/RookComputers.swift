import Combine
import ComputerBridge
import ComputerCore
import ComputerEngine
import Foundation
import HubLink
import NoodleComputerTools
import NoodleCore
import NoodleRuntimeSettings
import NoodleSettingsUI
import RookCore
import SwiftUI

/// The computers Rook's Missions use: Noodle Computer's engine, run inside Rook, shown with Noodle Computer's own
/// views, which Rook compiles. The champion makes them in the main window, as agents are made, and chooses a
/// Mission's computers with its team; an agent reaches one through Noodle's computer tool only while it shares an
/// open Mission with it, which `MissionComputers` works out and the broker enforces.
@MainActor @Observable final class RookComputers {
    let store: ComputerStore
    @ObservationIgnored private let provider: ComputerProvider
    /// Where file transfers wait between the computer tool and the engine.
    @ObservationIgnored private let staging: URL
    @ObservationIgnored private let model: RookModel
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    /// Marks computers whose image has a newer one, as Noodle Computer does, so they offer Upgrade. Rook keeps
    /// its computers as long as it runs, so this runs as long too.
    @ObservationIgnored private var imageUpdates: Task<Void, Never>?
    @ObservationIgnored private let root: URL
    /// Each Mission's gateway while any of its computers runs, and the Missions whose gateway is up, for the marker.
    @ObservationIgnored private var gateways: [UUID: ComputerGateway] = [:]
    @ObservationIgnored private var startingGateways: [UUID: Task<ComputerGateway, Error>] = [:]
    @ObservationIgnored private var appliedPolicies: [UUID: GatewayPolicy] = [:]
    private(set) var runningGateways: Set<UUID> = []
    /// Which Mission's gateway each running computer is cabled to; absent while it uses NAT.
    @ObservationIgnored private var placements: [UUID: UUID] = [:]
    /// What each gateway's audit lines have already said, so a scan of a thousand ports is one line per address.
    @ObservationIgnored private var reported: [UUID: Set<String>] = [:]
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var gatewayWatch: Task<Void, Never>?

    /// Only Linux computers and SSH: Windows and this Mac need helpers Rook does not carry.
    static let kinds: Set<ComputerKind> = [.container, .ssh]

    init(model: RookModel, root: URL) throws {
        self.model = model
        self.root = root
        store = try ComputerStore(root: root)
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("ComputerTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Rook answers the tool itself, so the engine opens no socket; the path only places its transfers.
        provider = try ComputerProvider(store: store, socket: staging.appendingPathComponent("computer.sock"), listens: false)
        store.provider = provider
        // A computer deleted, wherever from, leaves every Mission that had it.
        store.$sessions.dropFirst().receive(on: RunLoop.main).sink { [weak self] sessions in
            self?.forgetDeleted(keeping: Set(sessions.map(\.id)))
        }.store(in: &subscriptions)
        imageUpdates = Task { [store] in await store.watchImageUpdates() }
        store.network = { [weak self] session in try await self?.network(for: session) ?? .nat }
        watchMissions()
    }

    private func forgetDeleted(keeping ids: Set<UUID>) {
        let gone = Set(model.missions.flatMap(\.computers)).subtracting(ids)
        for id in gone {
            do { try model.store.forgetComputer(id, named: "a computer", by: .champion(model.champion)) }
            catch { model.problem = error.localizedDescription }
        }
    }

    /// Noodle's computer tool, answered in this process. The broker has already checked the agent may use the computer.
    var tool: ComputerToolProvider {
        let provider = provider, staging = staging
        let peer = Bundle.main.bundleIdentifier ?? "rook"
        return ComputerToolProvider(stagingRoot: { staging }) { request in
            try await provider.handle(request, peer: peer, stagingRoot: staging)
        }
    }

    var computers: [ComputerSession] { store.sessions.filter { Self.kinds.contains($0.computer.kind) } }

    func session(_ id: UUID) -> ComputerSession? { computers.first { $0.id == id } }
}

// MARK: Gateways

/// Every Linux computer in an open Mission reaches the network only through that Mission's gateway, which lets
/// through its scope, the services opened for it and package sources, and stops and reports the rest. Computers in
/// no Mission use NAT, as in Noodle Computer.
extension RookComputers {
    /// What a Mission's gateway lets through: its targets, its opened services and package sources; its deny lines win.
    static func policy(for mission: Mission) -> GatewayPolicy {
        func rule(_ target: ScopeRule.Target) -> GatewayPolicy.Rule {
            switch target {
            case .host(let name), .subdomains(let name): .domain(name)
            case .address(let address): .address(address)
            case .network(let address, let prefix): .network(address, prefix: prefix)
            }
        }
        let scope = mission.scope.compactMap { try? ScopeRule($0) }
        let exceptions = mission.exceptions.compactMap { try? ScopeRule($0) }
        return GatewayPolicy(
            allowed: scope.filter { !$0.isExcluded }.map { rule($0.target) } + exceptions.map { rule($0.target) } + GatewayPolicy.packageSources,
            denied: scope.filter(\.isExcluded).map { rule($0.target) })
    }

    /// The open Mission whose network a computer uses.
    // TODO: A computer in several open Missions takes the newest one's network; the champion should choose.
    func networkMission(for computer: UUID) -> Mission? {
        model.missions.filter { !$0.isClosed && $0.computers.contains(computer) }.max { $0.number < $1.number }
    }

    func gatewayRunning(for mission: UUID) -> Bool { runningGateways.contains(mission) }

    /// Asked by the engine as a Linux computer starts.
    fileprivate func network(for session: ComputerSession) async throws -> ComputerNetwork {
        guard session.computer.networkEnabled, let mission = networkMission(for: session.id) else {
            placements[session.id] = nil
            return .nat
        }
        let gateway = try await gateway(for: mission)
        let attachment = try await gateway.attach(session.id)
        placements[session.id] = mission.id
        return .gateway(attachment)
    }

    /// The Mission's gateway, started with its policy if it is not running; one start however many computers ask.
    private func gateway(for mission: Mission) async throws -> ComputerGateway {
        if let gateway = gateways[mission.id], await gateway.isRunning { return gateway }
        if let starting = startingGateways[mission.id] { return try await starting.value }
        let policy = Self.policy(for: mission)
        let gateway = ComputerGateway(id: mission.id, directory: root.appendingPathComponent("Gateways/\(mission.id.uuidString)", isDirectory: true),
                                      cache: store.imageCache, kernel: store.kernel)
        let starting = Task { try await gateway.start(policy: policy); return gateway }
        startingGateways[mission.id] = starting
        defer { startingGateways[mission.id] = nil }
        _ = try await starting.value
        gateways[mission.id] = gateway
        appliedPolicies[mission.id] = policy
        runningGateways.insert(mission.id)
        watchGateways()
        return gateway
    }

    /// Follows every change to the Missions: a new scope or opened service, a computer added or taken away, a close.
    fileprivate func watchMissions() {
        withObservationTracking { _ = model.missions } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.watchMissions()
            }
        }
    }

    /// One pass at a time, each after the last.
    private func reconcile() {
        let previous = reconciling
        reconciling = Task { [weak self] in
            await previous?.value
            await self?.reconcileNow()
        }
    }

    private func reconcileNow() async {
        let missions = model.missions
        for (id, gateway) in gateways {
            if let mission = missions.first(where: { $0.id == id }), !mission.isClosed {
                let policy = Self.policy(for: mission)
                guard appliedPolicies[id] != policy else { continue }
                do { try await gateway.apply(policy); appliedPolicies[id] = policy }
                catch { model.problem = "The gateway of \(mission.reference) kept its old rules: \(error.localizedDescription)" }
            }
        }
        for session in computers where session.computer.kind == .container && session.computer.networkEnabled && !session.phase.busy {
            let current = placements[session.id]
            guard session.phase == .running, let runtime = session.container else {
                if let current { await gateways[current]?.detach(session.id) }
                placements[session.id] = nil
                continue
            }
            let desired = networkMission(for: session.id)
            guard desired?.id != current else { continue }
            do {
                if let desired {
                    let attachment = try await gateway(for: desired).attach(session.id)
                    try await runtime.plug(attachment)
                    session.append("\nNow on the network of \(desired.reference).\n")
                } else {
                    // TODO: A computer that leaves its last Mission stays unplugged until it restarts on NAT.
                    try await runtime.plug(nil)
                    session.append("\nUnplugged: it is in no open Mission. Restart it to use NAT.\n")
                }
                if let current { await gateways[current]?.detach(session.id) }
                placements[session.id] = desired?.id
            } catch { model.problem = "\(session.computer.name) could not change networks: \(error.localizedDescription)" }
        }
        // A gateway no computer uses stops; its disk keeps its packages for next time.
        for (id, gateway) in gateways where !placements.values.contains(id) {
            await gateway.stop()
            gateways[id] = nil
            appliedPolicies[id] = nil
            reported[id] = nil
            runningGateways.remove(id)
        }
    }

    /// Copies each gateway's firewall and DNS logs into its Mission's folder, and what it stopped into the audit log,
    /// while any runs.
    private func watchGateways() {
        guard gatewayWatch == nil else { return }
        gatewayWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !self.gateways.isEmpty else { self?.gatewayWatch = nil; return }
                // Computers that stopped free their slots, and a gateway none uses stops.
                self.reconcile()
                for (id, gateway) in self.gateways {
                    // A busy scan can log more than one read takes; a few more reads catch up.
                    for _ in 0..<20 {
                        guard let records = try? await gateway.records() else { break }
                        await self.keep(records, of: gateway, in: id)
                        if !records.more { break }
                    }
                }
            }
        }
    }

    private func keep(_ records: GatewayRecords, of gateway: ComputerGateway, in mission: UUID) async {
        var computers: [Int: (id: UUID, name: String)] = [:]
        for slot in Set(records.firewall.compactMap(\.slot) + records.lookups.compactMap(\.slot)) {
            guard let id = await gateway.occupant(ofSlot: slot) else { continue }
            computers[slot] = (id, session(id)?.computer.name ?? "A computer")
        }
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ fields: [String: Any?]) -> String? {
            let present = fields.compactMapValues { $0 }
            guard let data = try? JSONSerialization.data(withJSONObject: present, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let network = records.firewall.compactMap { entry in
            line(["time": time.string(from: entry.time), "computer": entry.slot.flatMap { computers[$0]?.name },
                  "computerID": entry.slot.flatMap { computers[$0]?.id.uuidString }, "verdict": entry.verdict.rawValue,
                  "source": entry.source, "destination": entry.destination, "name": entry.name, "port": entry.port,
                  "protocol": entry.protocol, "flags": entry.flags.isEmpty ? nil : entry.flags])
        }
        let dns = records.lookups.compactMap { lookup in
            line(["time": time.string(from: lookup.time), "computer": lookup.slot.flatMap { computers[$0]?.name },
                  "computerID": lookup.slot.flatMap { computers[$0]?.id.uuidString }, "name": lookup.name,
                  "type": lookup.type, "answers": lookup.answers])
        }
        do {
            try model.store.appendLog(network, to: "network.log", in: mission)
            try model.store.appendLog(dns, to: "dns.log", in: mission)
        } catch { model.problem = "Could not keep the gateway's log: \(error.localizedDescription)" }
        // The audit log says once per address what the gateway stopped; the network log has every attempt.
        var details: [String] = []
        for entry in records.firewall where entry.verdict != .allowed {
            let key = "\(entry.destination) \(entry.port ?? 0) \(entry.protocol)"
            guard reported[mission, default: []].insert(key).inserted else { continue }
            let computer = entry.slot.flatMap { computers[$0]?.name } ?? "A computer"
            let destination = entry.destination + (entry.name.map { " (\($0))" } ?? "")
            details.append("The gateway stopped \(computer) reaching \(destination)\(entry.port.map { " port \($0)" } ?? "") (\(entry.protocol)): "
                           + (entry.verdict == .denied ? "the scope denies it." : "it is outside the scope."))
        }
        details += records.conflicts.map { "\($0) answers for names both in and out of scope, so the gateway keeps it closed." }
        for detail in details {
            // TODO: Gateway lines are audited in the champion's name; the audit log has no actor for Rook itself.
            do { try model.store.record("network", detail: detail, in: mission, by: .champion(model.champion)) }
            catch { model.problem = error.localizedDescription }
        }
    }
}

extension EnvironmentValues {
    /// Nil in scenarios and tests, which run no computers.
    @Entry var rookComputers: RookComputers?
}

// MARK: Making one

/// What New Computer opens: Noodle Computer's own sheets, a Linux computer from a template or one reached over SSH.
enum NewComputerKind: String, Identifiable {
    case linux, ssh
    var id: Self { self }
    /// As Noodle Computer names them, but a server reached over SSH is a connection here.
    var title: String { self == .linux ? "New Linux Container" : "New SSH Connection" }
}

/// Shows Noodle Computer's sheet for `kind`, with its download progress, then tells `created` which computer it made.
struct NewComputerSheet: View {
    let computers: RookComputers
    let kind: NewComputerKind
    let created: (UUID) -> Void
    @State private var before: Set<UUID> = []

    var body: some View {
        Group {
            switch kind {
            case .linux: NewComputerView(store: computers.store)
            case .ssh: NewSSHComputerView(store: computers.store)
            }
        }
        .onAppear { before = Set(computers.computers.map(\.id)) }
        .onDisappear {
            if let made = computers.computers.first(where: { !before.contains($0.id) }) { created(made.id) }
        }
    }
}

// MARK: In the sidebar

/// The sidebar's Computers, below the agents and groups, as agents are listed.
struct ComputersSidebarSection: View {
    let computers: RookComputers
    let model: RookModel
    let icons: Bool
    let select: (UUID) -> Void
    @ObservedObject private var store: ComputerStore

    init(computers: RookComputers, model: RookModel, icons: Bool, select: @escaping (UUID) -> Void) {
        self.computers = computers
        self.model = model
        self.icons = icons
        self.select = select
        store = computers.store
    }

    var body: some View {
        let sessions = computers.computers
        if !sessions.isEmpty {
            if icons {
                SidebarGridHeading(title: "Computers")
                ConversationIconGrid { items(sessions) }.padding(.vertical, 4)
            } else {
                Section("Computers") { items(sessions) }
            }
        }
    }

    private func items(_ sessions: [ComputerSession]) -> some View {
        ForEach(sessions) { session in
            ComputerSidebarItem(store: store, session: session, icons: icons, selected: model.selection == session.id) { select(session.id) }
                .tag(session.id)
        }
    }
}

private struct ComputerSidebarItem: View {
    @ObservedObject var store: ComputerStore
    @ObservedObject var session: ComputerSession
    let icons: Bool
    let selected: Bool
    let select: () -> Void
    @State private var deleting = false
    @State private var editing = false
    @State private var upgrading = false
    // Says a newer image is ready, as Noodle Computer's library does, in place of the status.
    private var detail: String { session.offersImageUpgrade && !session.phase.busy ? "Upgrade available" : session.phase.label }

    var body: some View {
        Group {
            if icons {
                Button(action: select) {
                    SidebarItemTile(title: session.computer.name, detail: detail, tone: AnyShapeStyle(.secondary),
                                    emphasized: false, selected: selected) { size in ComputerMark(session: session, size: size) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(session.computer.name)
            } else {
                SidebarItemRow(title: session.computer.name, detail: detail, timestamp: "") { size in
                    ComputerMark(session: session, size: size)
                }
                .sidebarItemInsets()
            }
        }
        .contextMenu {
            Button("Edit Computer…") { editing = true }
            Divider()
            if session.offersImageUpgrade {
                ComputerImageUpdateButton(session: session) { upgrading = true }
                Divider()
            }
            Button(session.phase == .running ? "Stop" : "Start") {
                Task { if session.phase == .running { await store.stop(session) } else { await store.start(session) } }
            }
            .disabled(session.phase.busy)
            Divider()
            Button("Delete Computer", role: .destructive) { deleting = true }.disabled(!session.canDelete)
        }
        .computerImageUpdateConfirmation(store: store, session: session, isPresented: $upgrading)
        .sheet(isPresented: $editing) { EditComputerView(store: store, session: session) }
        .alert(ComputerDeletion.title(session.computer), isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button(ComputerDeletion.action(session.computer), role: .destructive) { store.remove(session) }
        } message: { Text(ComputerDeletion.message(session.computer)) }
    }
}

/// Noodle Computer's icon for a computer, with its status as a dot, as its library shows it.
struct ComputerMark: View {
    @ObservedObject var session: ComputerSession
    let size: CGFloat

    var body: some View {
        ComputerIcon(appearance: session.computer.appearance ?? .init(), symbol: session.computer.displaySymbol, size: size)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(status).frame(width: max(6, size / 4), height: max(6, size / 4))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            .help(session.phase.label)
    }

    private var status: Color {
        switch session.phase {
        case .running: .green
        case .starting, .stopping, .updating, .setupRequired: .orange
        case .failed: .red
        case .stopped: .gray
        }
    }
}

// MARK: A Mission's computers

/// Edit Mission's Computers row, beside its team and folders: opens a sheet to choose them.
struct MissionComputersRow: View {
    let computers: RookComputers
    @Binding var selection: [UUID]
    @Binding var names: [UUID: String]
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack {
                Label("Computers", systemImage: "desktopcomputer")
                Spacer()
                Text(selection.isEmpty ? "None" : "\(selection.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Every agent in this Mission can use these computers while it is open.")
        .sheet(isPresented: $choosing) { MissionComputersSheet(computers: computers, selection: $selection, names: $names) }
        .onAppear { for session in computers.computers { names[session.id] = session.computer.name } }
    }
}

/// Choosing a Mission's computers with Noodle's own picker, as Noodle gives a bot its computers: the chosen ones in a
/// grid, and Add Computers to pick from the rest or make a new one.
private struct MissionComputersSheet: View {
    let computers: RookComputers
    @Binding var selection: [UUID]
    @Binding var names: [UUID: String]
    @ObservedObject private var store: ComputerStore
    @State private var draft: [UUID]
    @State private var creating: NewComputerKind?
    @Environment(\.dismiss) private var dismiss

    init(computers: RookComputers, selection: Binding<[UUID]>, names: Binding<[UUID: String]>) {
        self.computers = computers
        _selection = selection
        _names = names
        store = computers.store
        _draft = State(initialValue: selection.wrappedValue)
    }

    /// The chosen ones as a set for the picker, kept in the order they were chosen.
    private var chosen: Binding<Set<UUID>> {
        Binding(get: { Set(draft) }, set: { ids in
            draft = draft.filter(ids.contains) + computers.computers.map(\.id).filter { ids.contains($0) && !draft.contains($0) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetHeader).keyboardShortcut(.cancelAction)
                Spacer()
                Text("Computers").font(.headline)
                Spacer()
                Button("Done") {
                    for session in computers.computers { names[session.id] = session.computer.name }
                    selection = draft
                    dismiss()
                }
                .buttonStyle(.sheetHeader).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            CompanionAssignmentPicker(title: "Computers", noun: "computer", symbol: "desktopcomputer",
                items: computers.computers.map {
                    CompanionAssignmentItem(id: $0.id, name: $0.computer.name, state: $0.phase.label, symbol: $0.computer.displaySymbol,
                                            colour: 0, detail: $0.computer.displayType)
                },
                selectedIDs: chosen,
                createPrompt: VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.largeTitle)
                    Text("No computers yet")
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal, 12),
                openLibraryButton: EmptyView(), notice: EmptyView(),
                owner: "mission", newKinds: [NewComputerKind.linux.title, NewComputerKind.ssh.title],
                onNewKind: { title in creating = title == NewComputerKind.ssh.title ? .ssh : .linux },
                avatar: { item, size in
                    AnyView(ComputerIcon(appearance: .init(), symbol: item.symbol, size: size)
                        .environment(\.offersComputerAppearance, false).environment(\.computerIconColours, (Color.markDisc, Color.markInk)))
                })
                .padding(20)
        }
        .frame(width: 540)
        .noodleSheetSizing()
        .sheet(item: $creating) { kind in
            NewComputerSheet(computers: computers, kind: kind) { id in if !draft.contains(id) { draft.append(id) } }
        }
    }
}

/// A Mission's computers at the top of its conversation, after its agents; each opens its computer.
struct MissionComputerChips: View {
    let computers: RookComputers
    let mission: Mission
    let open: (UUID) -> Void
    @ObservedObject private var store: ComputerStore

    init(computers: RookComputers, mission: Mission, open: @escaping (UUID) -> Void) {
        self.computers = computers
        self.mission = mission
        self.open = open
        store = computers.store
    }

    var body: some View {
        if computers.gatewayRunning(for: mission.id) {
            Image(systemName: "network.badge.shield.half.filled")
                .foregroundStyle(.secondary)
                .help("This Mission's computers reach only its scope, the services opened for it and package sources.")
        }
        ForEach(mission.computers.compactMap(computers.session)) { session in
            MissionComputerChip(session: session) { open(session.id) }
        }
    }
}

private struct MissionComputerChip: View {
    @ObservedObject var session: ComputerSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                ComputerMark(session: session, size: 16)
                Text(session.computer.name)
            }
        }
        .buttonStyle(.plain)
        .help("\(session.computer.name), \(session.phase.label)")
        .padding(.trailing, 4)
    }
}
