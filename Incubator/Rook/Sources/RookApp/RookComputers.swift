import ComputerBridge
import ComputerCore
import ComputerEngine
import Foundation
import NoodleComputerTools
import NoodleCore
import NoodleRuntimeSettings
import NoodleSettingsUI
import RookCore
import SwiftUI

/// The computers Rook's Missions use: Noodle Computer's engine, run inside Rook. The champion makes them in
/// Settings › Computers and assigns them to Missions; an agent reaches one through Noodle's computer tool only
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

// MARK: Settings › Computers

struct ComputersSettingsView: View {
    let computers: RookComputers
    @ObservedObject private var store: ComputerStore
    @State private var creating: NewComputerSheet.Kind?
    @State private var deleting: ComputerSession?

    init(computers: RookComputers) {
        self.computers = computers
        store = computers.store
    }

    var body: some View {
        Form {
            Section {
                if computers.computers.isEmpty {
                    Text("No computers").foregroundStyle(.secondary)
                } else {
                    SettingsRowList(computers.computers) { session in ComputerRow(computers: computers, session: session) { deleting = session } }
                }
            } footer: {
                HStack {
                    Spacer()
                    Menu("New Computer") {
                        ForEach(ContainerRegistry.bundled.templates, id: \.id) { template in
                            Button(template.name) { creating = .template(template) }
                        }
                        Divider()
                        Button("SSH") { creating = .ssh }
                    }
                    .fixedSize()
                }
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $creating) { kind in NewComputerSheet(computers: computers, kind: kind) }
        .alert("Delete \(deleting?.computer.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { computers.delete(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its files are deleted, and it is taken out of every Mission it is in.")
        }
    }
}

private struct ComputerRow: View {
    let computers: RookComputers
    @ObservedObject var session: ComputerSession
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.computer.kind.symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.computer.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.phase == .running {
                Button("Stop") { computers.stop(session) }.buttonStyle(.accentLink)
            } else if session.phase.canStart {
                Button("Start") { computers.start(session) }.buttonStyle(.accentLink)
            }
            Menu {
                Button("Delete", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(session.computer.name) actions")
        }
    }

    private var detail: String {
        var parts = [session.phase.label]
        if let ssh = session.computer.ssh { parts.append(ssh.address) }
        if case .failed(let message) = session.phase { parts.append(message) }
        return parts.joined(separator: " · ")
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

    init(computers: RookComputers, kind: Kind) {
        self.computers = computers
        self.kind = kind
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
            if let problem { failure = problem } else { dismiss() }
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
                        if others.isEmpty { Text("No other computers") }
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
