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

    /// Only Linux computers and SSH: Windows and this Mac need helpers Rook does not carry.
    static let kinds: Set<ComputerKind> = [.container, .ssh]

    init(model: RookModel, root: URL) throws {
        self.model = model
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

    var body: some View {
        Group {
            if icons {
                Button(action: select) {
                    SidebarItemTile(title: session.computer.name, detail: session.phase.label, tone: AnyShapeStyle(.secondary),
                                    emphasized: false, selected: selected) { size in ComputerMark(session: session, size: size) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(session.computer.name)
            } else {
                SidebarItemRow(title: session.computer.name, detail: session.phase.label, timestamp: "") { size in
                    ComputerMark(session: session, size: size)
                }
                .sidebarItemInsets()
            }
        }
        .contextMenu {
            Button("Edit Computer…") { editing = true }
            Divider()
            Button(session.phase == .running ? "Stop" : "Start") {
                Task { if session.phase == .running { await store.stop(session) } else { await store.start(session) } }
            }
            .disabled(session.phase.busy)
            Divider()
            Button("Delete Computer", role: .destructive) { deleting = true }.disabled(!session.canDelete)
        }
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
