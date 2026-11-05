import AppKit
import ComputerCore
import ComputerEngine
import NoodleSettingsUI
import SwiftUI
import UniformTypeIdentifiers

/// How an SSH computer signs in, as chosen in a form. Keep Current is offered only when editing.
struct SSHSignInDraft {
    enum Choice: String, CaseIterable, Identifiable {
        case keep = "Current", nothing = "None", newKey = "New Key", existingKey = "Existing Key", password = "Password"
        var id: Self { self }
        var help: String {
            switch self {
            case .keep: "Keep the key or password this computer signs in with"
            case .nothing: "No key or password, for servers that trust your network, such as Tailscale SSH"
            case .newKey: "A key made for this computer"
            case .existingKey: "An Ed25519 or ECDSA private key without a passphrase"
            case .password: "The server account’s password"
            }
        }
    }
    var choice = Choice.nothing
    var password = ""
    var newKey = SSHKey.generate()
    var existingKey = ""

    var secret: SSHSecret? {
        get throws {
            switch choice {
            case .keep, .nothing: return nil
            case .newKey: return .key(newKey)
            case .existingKey: return .key(try SSHKey(text: existingKey))
            case .password: return .password(password)
            }
        }
    }
    var isComplete: Bool {
        switch choice {
        case .keep, .nothing, .newKey: true
        case .existingKey: !existingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password: !password.isEmpty
        }
    }
}

struct SSHSignInFields: View {
    @Binding var draft: SSHSignInDraft
    var keeps = false
    @State private var choosingKey = false
    @State private var unreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In").font(.caption.weight(.semibold))
            Picker("Sign In", selection: $draft.choice) {
                ForEach(SSHSignInDraft.Choice.allCases.filter { keeps || $0 != .keep }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help(draft.choice.help)
            switch draft.choice {
            case .keep, .nothing: EmptyView()
            case .password:
                SecureField("Password", text: $draft.password).textFieldStyle(.roundedBorder)
            case .newKey:
                let line = (try? draft.newKey.publicLine) ?? ""
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "key").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy public key")
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
                .help("Add this line to ~/.ssh/authorized_keys on the server first")
            case .existingKey:
                TextEditor(text: $draft.existingKey).font(.system(.callout, design: .monospaced))
                    .frame(height: 96).scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.existingKey.isEmpty {
                            Text("Paste a private key").font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button("Choose File…") { choosingKey = true }
                    if unreadable { Text("Choose a private key file.").foregroundStyle(.red) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 64 * 1024 else { unreadable = true; return }
            unreadable = false
            draft.existingKey = String(decoding: data, as: UTF8.self)
        }
    }
}

/// A computer reached over SSH. Creating it signs in once, so a wrong address or sign-in shows here.
struct NewSSHComputerView: View {
    @ObservedObject var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
    @State private var name = ""
    @State private var address = ""
    @State private var signIn = SSHSignInDraft()
    @State private var appearance = ComputerAppearance()
    @State private var failure: String?
    private var creating: Bool { store.creationStatus != nil }
    private var destination: SSHDestination? { try? SSHDestination(address: address) }
    private var draft: Computer? {
        guard let destination else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var computer = Computer(name: trimmed.isEmpty ? destination.host : trimmed, kind: .ssh)
        computer.ssh = destination
        computer.appearance = appearance
        return (try? computer.validate()) == nil ? nil : computer
    }
    private var canCreate: Bool { !creating && draft != nil && signIn.isComplete }

    var body: some View {
        Group {
            if creating {
                ComputerCreationProgressView(store: store)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(.blue)
                        Spacer()
                        Text("New SSH Computer").font(.headline)
                        Spacer()
                        Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(!canCreate)
                            .foregroundStyle(canCreate ? Color.blue : .secondary)
                    }.buttonStyle(.plain).padding(20)
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                ComputerIconButton(appearance: $appearance, symbol: ComputerKind.ssh.symbol)
                                TextField("Name", text: $name, prompt: Text(destination?.host ?? "Name"))
                                    .autocorrectionDisabled().textFieldStyle(.roundedBorder).lineLimit(1)
                            }
                            TextField("Address", text: $address, prompt: Text("user@server"))
                                .autocorrectionDisabled().textFieldStyle(.roundedBorder).lineLimit(1)
                                .help("user@server or user@server:port")
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
                        SSHSignInFields(draft: $signIn)
                        ComputerAppearanceRow(appearance: $appearance)
                        if let failure {
                            Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(20)
                }
                .frame(width: 580)
            }
        }
        .noodleSheetSizing()
        .interactiveDismissDisabled(creating)
    }

    private func create() {
        guard let computer = draft else { return }
        let secret: SSHSecret?
        do { secret = try signIn.secret } catch { failure = error.localizedDescription; return }
        failure = nil
        Task {
            if await store.create(computer, source: nil, sshSecret: secret) {
                dismiss()
                if startNewComputersAutomatically, let session = store.sessions.first(where: { $0.id == computer.id }) {
                    await store.start(session)
                }
            } else {
                failure = store.creationWasCancelled ? nil : store.error
                store.error = nil
            }
        }
    }
}

/// A new address or sign-in for an SSH computer, kept only once the server lets it in.
struct ChangeSSHSignInView: View {
    @ObservedObject var store: ComputerStore
    @ObservedObject var session: ComputerSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var signIn = SSHSignInDraft()
    @State private var checking = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    private var destination: SSHDestination? { try? SSHDestination(address: address) }
    private var canSave: Bool { !checking && destination != nil && signIn.isComplete }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(.blue)
                Spacer()
                Text("Change Sign In").font(.headline)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
                    .foregroundStyle(canSave ? Color.blue : .secondary)
            }.buttonStyle(.plain).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                TextField("Address", text: $address, prompt: Text("user@server"))
                    .autocorrectionDisabled().textFieldStyle(.roundedBorder).lineLimit(1)
                    .help("user@server or user@server:port")
                    .padding(12)
                    .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
                SSHSignInFields(draft: $signIn, keeps: session.computer.ssh?.credential != nil)
                if checking {
                    ProgressView("Connecting…").controlSize(.small)
                } else if let failure {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).disabled(checking)
        }
        .frame(width: 540).noodleSheetSizing()
        .onAppear {
            address = session.computer.ssh?.address ?? ""
            if session.computer.ssh?.credential != nil { signIn.choice = .keep }
        }
    }

    private func save() {
        guard let destination else { return }
        let secret: SSHSecret?
        do { secret = try signIn.secret } catch { failure = error.localizedDescription; return }
        failure = nil
        checking = true
        task = Task {
            defer { checking = false }
            do {
                try await store.changeSignIn(session, to: destination, secret: secret, keepSaved: signIn.choice == .keep)
                dismiss()
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }
}

/// What deleting a computer does, which depends on what it is.
enum ComputerDeletion {
    static func title(_ computer: Computer) -> String {
        switch computer.kind {
        case .localMac: "Delete \(computer.name) and its account?"
        case .ssh: "Delete \(computer.name)?"
        default: "Move \(computer.name) to Trash?"
        }
    }
    static func action(_ computer: Computer) -> String {
        switch computer.kind {
        case .localMac: "Delete Account"
        case .ssh: "Delete"
        default: "Move to Trash"
        }
    }
    static func message(_ computer: Computer) -> String {
        switch computer.kind {
        case .localMac: "This permanently deletes the managed account and its home directory. Stop preserves them; Delete removes them."
        case .ssh: "Its key or password is removed from this Mac. Nothing changes on the server."
        default: "The computer and its disks will be moved to the Trash."
        }
    }
}

/// A server's sign-in message with its links clickable, such as Tailscale's check link.
enum ComputerNotice {
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
