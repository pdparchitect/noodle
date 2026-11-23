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

/// The computers Rook's Missions use: Noodle Computer's engine, run inside Rook. The champion makes them in the
/// main window, as agents are made, and assigns them to Missions; an agent reaches one through Noodle's computer tool only
/// while it shares an open Mission with it, which `MissionComputers` works out and the broker enforces.
@MainActor @Observable final class RookComputers {
    let store: ComputerStore
    @ObservationIgnored private let provider: ComputerProvider
    /// Where file transfers wait between the computer tool and the engine.
    @ObservationIgnored private let staging: URL
    @ObservationIgnored private let model: RookModel

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

    /// Makes a computer; nil when it worked, otherwise what went wrong.
    func create(_ computer: Computer, secret: SSHSecret? = nil) async -> String? {
        guard await store.create(computer, source: nil, sshSecret: secret, selects: false) else {
            defer { store.error = nil }
            return store.creationWasCancelled ? nil : store.error ?? "The computer could not be made."
        }
        return nil
    }

    func start(_ session: ComputerSession) { Task { await store.start(session) } }
    func stop(_ session: ComputerSession) { Task { await store.stop(session) } }

    /// Stops and deletes it, then takes it out of every Mission that had it.
    func delete(_ session: ComputerSession) {
        Task {
            if session.phase != .stopped { await store.stop(session) }
            guard session.canDelete else { return }
            let id = session.id, name = session.computer.name
            store.remove(session)
            guard store.error == nil else { return }
            do { try model.store.forgetComputer(id, named: name, by: .champion(model.champion)) }
            catch { model.problem = error.localizedDescription }
        }
    }
}

extension EnvironmentValues {
    /// Nil in scenarios and tests, which run no computers.
    @Entry var rookComputers: RookComputers?
}

// MARK: In the main window

/// What New Computer offers, in the sidebar's + menu and a Mission's inspector: each template, then SSH.
struct NewComputerMenuItems: View {
    let choose: (NewComputerSheet.Kind) -> Void

    var body: some View {
        ForEach(ContainerRegistry.bundled.templates, id: \.id) { template in
            Button(template.name) { choose(.template(template)) }
        }
        Button("SSH") { choose(.ssh) }
    }
}

/// The sidebar's Computers, below the agents and groups, as agents are listed.
struct ComputersSidebarSection: View {
    let computers: RookComputers
    let model: RookModel
    let icons: Bool
    let select: (UUID) -> Void
    @ObservedObject private var store: ComputerStore
    @State private var deleting: ComputerSession?

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
            Group {
                if icons {
                    SidebarGridHeading(title: "Computers")
                    ConversationIconGrid { items(sessions) }.padding(.vertical, 4)
                } else {
                    Section("Computers") { items(sessions) }
                }
            }
            .alert("Delete \(deleting?.computer.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) { if let deleting { computers.delete(deleting) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its files are deleted, and it is taken out of every Mission it is in.")
            }
        }
    }

    private func items(_ sessions: [ComputerSession]) -> some View {
        ForEach(sessions) { session in
            ComputerSidebarItem(session: session, icons: icons, selected: model.selection == session.id) { select(session.id) }
                .tag(session.id)
                .contextMenu { ComputerActions(computers: computers, session: session) { deleting = session } }
        }
    }
}

private struct ComputerSidebarItem: View {
    @ObservedObject var session: ComputerSession
    let icons: Bool
    let selected: Bool
    let select: () -> Void

    var body: some View {
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
}

private struct ComputerMark: View {
    @ObservedObject var session: ComputerSession
    let size: CGFloat

    var body: some View {
        Image(systemName: session.computer.kind.symbol)
            .font(.system(size: size * 0.55))
            .foregroundStyle(session.phase == .running ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(Circle().fill(.quaternary))
    }
}

/// Start or Stop, then Delete last.
private struct ComputerActions: View {
    let computers: RookComputers
    @ObservedObject var session: ComputerSession
    let delete: () -> Void

    var body: some View {
        if session.phase == .running {
            Button("Stop") { computers.stop(session) }
        } else if session.phase.canStart {
            Button("Start") { computers.start(session) }
        }
        Divider()
        Button("Delete", role: .destructive, action: delete)
    }
}

/// A computer selected in the sidebar: what it is, whether it runs, and the Missions that use it.
struct ComputerDetailView: View {
    let computers: RookComputers
    let model: RookModel
    @ObservedObject var session: ComputerSession
    @State private var deleting = false

    var body: some View {
        let missions = model.missions.filter { $0.computers.contains(session.id) }
        VStack(spacing: 18) {
            ComputerMark(session: session, size: 64)
            VStack(spacing: 4) {
                Text(session.computer.name).font(.title2.weight(.semibold))
                Text(kind).foregroundStyle(.secondary)
                Text(session.phase.label).font(.callout).foregroundStyle(.secondary)
                if case .failed(let message) = session.phase {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled).multilineTextAlignment(.center)
                }
            }
            HStack {
                if session.phase == .running {
                    Button("Stop") { computers.stop(session) }
                } else if session.phase.canStart {
                    Button("Start") { computers.start(session) }
                }
                Button("Delete", role: .destructive) { deleting = true }
            }
            VStack(spacing: 6) {
                Text("Missions").font(.subheadline.weight(.semibold))
                if missions.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(missions) { mission in
                    Button("\(mission.reference) \(mission.title)") { model.selection = mission.id }.buttonStyle(.accentLink)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Delete \(session.computer.name)?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { computers.delete(session); model.selection = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files are deleted, and it is taken out of every Mission it is in.")
        }
    }

    private var kind: String {
        if let ssh = session.computer.ssh { return "SSH · \(ssh.address)" }
        return session.computer.template?.name ?? "Linux"
    }
}

/// A new Linux computer from a template, or a computer reached over SSH. Creating an SSH computer signs in once,
/// so a wrong address or sign-in shows here.
struct NewComputerSheet: View {
    enum Kind: Identifiable {
        case template(ComputerTemplate), ssh
        var id: String { if case .template(let template) = self { template.id } else { "ssh" } }
    }
    enum SignIn: String, CaseIterable, Identifiable {
        case none = "None", newKey = "New Key", existingKey = "Existing Key", password = "Password"
        var id: Self { self }
    }

    let computers: RookComputers
    let kind: Kind
    /// Hears the new computer's ID, as when a Mission's inspector adds what it makes.
    var created: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: ComputerStore
    @State private var name = ""
    @State private var address = ""
    @State private var signIn = SignIn.none
    @State private var newKey = SSHKey.generate()
    @State private var existingKey = ""
    @State private var password = ""
    @State private var failure: String?
    @State private var working = false

    init(computers: RookComputers, kind: Kind, created: @escaping (UUID) -> Void = { _ in }) {
        self.computers = computers
        self.kind = kind
        self.created = created
        store = computers.store
    }

    private var title: String {
        switch kind {
        case .template(let template): "New \(template.name) Computer"
        case .ssh: "New SSH Computer"
        }
    }

    private var draft: Computer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var computer: Computer
        switch kind {
        case .template(let template):
            computer = template.makeComputer(name: trimmed.isEmpty ? template.name : trimmed)
        case .ssh:
            guard let destination = try? SSHDestination(address: address) else { return nil }
            computer = Computer(name: trimmed.isEmpty ? destination.host : trimmed, kind: .ssh)
            computer.ssh = destination
        }
        return (try? computer.validate()) == nil ? nil : computer
    }

    private var secret: SSHSecret? {
        get throws {
            switch signIn {
            case .none: nil
            case .newKey: .key(newKey)
            case .existingKey: .key(try SSHKey(text: existingKey))
            case .password: .password(password)
            }
        }
    }

    private var complete: Bool {
        switch signIn {
        case .none, .newKey: true
        case .existingKey: !existingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password: !password.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(working || draft == nil || !complete)
            }
            .padding(20)
            Divider()
            Form {
                TextField("Name", text: $name)
                if case .ssh = kind {
                    TextField("Address", text: $address, prompt: Text("user@server"))
                        .help("user@server or user@server:port")
                    Picker("Sign In", selection: $signIn) {
                        ForEach(SignIn.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch signIn {
                    case .none: EmptyView()
                    case .newKey:
                        LabeledContent("Public Key") {
                            Text((try? newKey.publicLine) ?? "").font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                        }
                        .help("Add this line to the server account's authorized_keys")
                    case .existingKey:
                        TextField("Private Key", text: $existingKey, axis: .vertical).lineLimit(3...6).font(.caption.monospaced())
                            .help("An Ed25519 or ECDSA private key without a passphrase")
                    case .password:
                        SecureField("Password", text: $password)
                    }
                }
                if let status = store.creationStatus, working {
                    LabeledContent("Status") { Text(status).foregroundStyle(.secondary) }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .disabled(working)
        }
        .frame(width: 520)
        .noodleSheetSizing()
    }

    private func create() {
        guard let draft else { return }
        let secret: SSHSecret?
        do { secret = try self.secret } catch { failure = error.localizedDescription; return }
        working = true
        failure = nil
        Task {
            let problem = await computers.create(draft, secret: secret)
            working = false
            if let problem { failure = problem } else { created(draft.id); dismiss() }
        }
    }
}

// MARK: A Mission's computers

/// The computers assigned to a Mission, in its inspector. Only the champion, who uses this window, assigns them.
struct MissionComputersSection: View {
    let model: RookModel
    let mission: Mission
    let computers: RookComputers
    @ObservedObject private var store: ComputerStore
    @State private var creating: NewComputerSheet.Kind?

    init(model: RookModel, mission: Mission, computers: RookComputers) {
        self.model = model
        self.mission = mission
        self.computers = computers
        store = computers.store
    }

    var body: some View {
        let assigned = mission.computers.compactMap(computers.session)
        let others = computers.computers.filter { !mission.computers.contains($0.id) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Computers").font(.subheadline.weight(.semibold))
                Spacer()
                if !mission.isClosed {
                    Menu {
                        ForEach(others) { session in Button(session.computer.name) { model.setComputer(session.id, named: session.computer.name, assigned: true, in: mission) } }
                        if !others.isEmpty { Divider() }
                        Menu("New Computer") { NewComputerMenuItems { creating = $0 } }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Add a computer to this Mission")
                        .accessibilityLabel("Add Computer")
                }
            }
            if assigned.isEmpty {
                Text("None").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(assigned) { session in
                MissionComputerRow(session: session, removable: !mission.isClosed) {
                    model.setComputer(session.id, named: session.computer.name, assigned: false, in: mission)
                }
            }
        }
        .sheet(item: $creating) { kind in
            NewComputerSheet(computers: computers, kind: kind) { id in
                guard let session = computers.session(id), let current = model.mission(mission.id) else { return }
                model.setComputer(id, named: session.computer.name, assigned: true, in: current)
            }
        }
    }
}

private struct MissionComputerRow: View {
    @ObservedObject var session: ComputerSession
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.computer.kind.symbol).foregroundStyle(.secondary)
            Text(session.computer.name).font(.callout)
            Text(session.phase.label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if removable {
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove from this Mission")
                    .accessibilityLabel("Remove \(session.computer.name)")
            }
        }
    }
}
