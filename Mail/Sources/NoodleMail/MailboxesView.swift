import AppKit
import MailBridge
import MailCore
import MailEngine
import NoodleSettingsUI
import Observation
import SwiftUI

/// The mailboxes as the window shows them. Passwords go straight to the secret store and are never shown again.
@MainActor @Observable final class MailboxesModel {
    let library: MailboxLibrary
    let secrets: MailSecretStorage
    let runtime: MailRuntime
    let lookup: MailServerLookup
    private(set) var mailboxes: [MailboxRecord] = []
    /// Why the socket couldn't start. Bots can't reach the mailboxes until it does.
    var serverFailure: String?
    var editing: MailboxEditing?

    init(library: MailboxLibrary, secrets: MailSecretStorage, runtime: MailRuntime, lookup: MailServerLookup = MailServerLookup()) {
        self.library = library
        self.secrets = secrets
        self.runtime = runtime
        self.lookup = lookup
        reload()
    }

    var failure: String? { serverFailure ?? library.failure }
    func reload() { library.reload(); mailboxes = library.mailboxes() }
    func hasPassword(_ id: UUID) -> Bool { secrets.hasPassword(for: id) }

    /// Saves the form, and the password when one was typed: an empty field keeps the stored one.
    @discardableResult
    func save(_ draft: MailboxDraft, password: String, id: UUID?) async throws -> MailboxRecord {
        guard id != nil || !password.isEmpty else {
            throw MailError("Enter the mailbox password (an app password if two-factor login is on).")
        }
        let record = try draft.record(id: id ?? UUID(), keeping: id.flatMap { library.mailbox($0) })
        try library.save(record)
        if !password.isEmpty { try secrets.setPassword(password, for: record.id) }
        // The next call signs in with what was just saved.
        await runtime.forget(record.id)
        reload()
        return record
    }

    func remove(_ id: UUID) async throws {
        try library.remove(id)
        try secrets.setPassword(nil, for: id)
        await runtime.forget(id)
        reload()
    }

    /// Signs in and lists the folders, the same way a bot's first call does.
    func test(_ id: UUID) async -> String {
        let response = await runtime.perform(MailRequest(.folders, mailboxID: id), caller: MailBuildIdentity.current.providerID)
        if let error = response.error { return error }
        let count = response.folders?.count ?? 0
        return "Signed in. \(count) folder\(count == 1 ? "" : "s")."
    }

    /// Find Servers: asks only about the address's domain.
    func findServers(for address: String) async -> MailServerLookupResult { await lookup.find(address: address) }
}

struct MailboxEditing: Identifiable {
    let id = UUID()
    /// nil for a new mailbox.
    let mailbox: UUID?
}

struct MailboxesView: View {
    @Bindable var model: MailboxesModel
    @State private var selection: UUID?
    @State private var status: String?
    @State private var problem: String?
    /// The mailbox waiting for the person's yes to Remove.
    @State private var pendingRemoval: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = model.failure {
                Text(failure).foregroundStyle(.red).padding(12)
            }
            List(selection: $selection) {
                ForEach(model.mailboxes) { mailbox in
                    HStack {
                        Image(systemName: "envelope")
                        VStack(alignment: .leading) {
                            Text(mailbox.name).font(.headline)
                            Text(mailbox.account.address).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.hasPassword(mailbox.id) { Text("No password").foregroundStyle(.orange) }
                    }
                    .tag(mailbox.id)
                    .contextMenu {
                        Button("Edit…") { model.editing = MailboxEditing(mailbox: mailbox.id) }
                        Button("Remove", role: .destructive) { pendingRemoval = mailbox.id }
                    }
                }
            }
            .overlay {
                if model.mailboxes.isEmpty {
                    ContentUnavailableView("No Mailboxes", systemImage: "envelope")
                }
            }
            Divider()
            HStack {
                Button { model.editing = MailboxEditing(mailbox: nil) } label: { Image(systemName: "plus") }
                    .help("Add a mailbox")
                Button { if let selection { model.editing = MailboxEditing(mailbox: selection) } } label: { Image(systemName: "pencil") }
                    .disabled(selection == nil).help("Edit the mailbox")
                Button { pendingRemoval = selection } label: { Image(systemName: "minus") }
                    .disabled(selection == nil).help("Remove the mailbox and its password")
                Button("Test Connection") { test() }.disabled(selection == nil)
                Spacer()
                if let status { Text(status).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(10)
        }
        .sheet(item: $model.editing) { editing in MailboxEditor(model: model, id: editing.mailbox) }
        .alert(MailBuildIdentity.current.appName, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .confirmationDialog("Remove “\(model.mailboxes.first { $0.id == pendingRemoval }?.name ?? "")”?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { id in
            Button("Remove", role: .destructive) { remove(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its password is deleted, and bots assigned to it lose access. Adding it again creates a new mailbox that needs assigning again.")
        }
    }

    private func remove(_ id: UUID) {
        Task {
            do { try await model.remove(id); selection = nil }
            catch { problem = error.localizedDescription }
        }
    }
    private func test() {
        guard let selection else { return }
        status = "Signing in…"
        Task { status = await model.test(selection) }
    }
}

/// Adds or edits one mailbox. Plain text isn't offered: the engine allows it only for test servers on this Mac.
struct MailboxEditor: View {
    let model: MailboxesModel
    let id: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MailboxDraft()
    @State private var password = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var finding = false
    /// What Find Servers last said, under its button.
    @State private var found: String?

    var body: some View {
        Form {
            Section("Mailbox") {
                TextField("Name", text: $draft.name, prompt: Text("Klára's invoices"))
                TextField("E-mail address", text: $draft.address)
                TextField("Username", text: $draft.username, prompt: Text("Same as the address"))
                SecureField("Password", text: $password, prompt: Text(id == nil ? "Required" : "Unchanged"))
                HStack {
                    Button("Find Servers") { findServers() }
                        .disabled(finding || draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Looks up this address's mail servers: first the domain's own settings, then Mozilla's public list of providers. Only the domain is sent, never the address.")
                    if finding { ProgressView().controlSize(.small) }
                }
                if let found { Text(found).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Section("Incoming mail (IMAP)") { server(host: $draft.imapHost, port: $draft.imapPort, security: $draft.imapSecurity) }
            Section("Outgoing mail (SMTP)") { server(host: $draft.smtpHost, port: $draft.smtpPort, security: $draft.smtpSecurity) }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onChange(of: draft.address) { found = nil }
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) }
        }
        .onAppear { if let id, let record = model.library.mailbox(id) { draft = MailboxDraft(record) } }
        .noodleSheetSizing()
    }

    @ViewBuilder private func server(host: Binding<String>, port: Binding<Int>, security: Binding<MailSecurity>) -> some View {
        TextField("Server", text: host)
        TextField("Port", value: port, format: .number.grouping(.never))
        Picker("Security", selection: security) {
            Text("TLS").tag(MailSecurity.tls)
            Text("STARTTLS").tag(MailSecurity.startTLS)
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.save(draft, password: password, id: id)
                password = ""
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }

    /// Applies the answer to the form as it is now: dropped if the domain changed meanwhile, otherwise it replaces the
    /// servers (even ones typed meanwhile), but not a username the person typed. A found answer also clears the old error.
    private func findServers() {
        finding = true
        found = nil
        let address = draft.address
        Task {
            let result = await model.findServers(for: address)
            found = draft.apply(result, lookedUp: address)
            if found != nil, case .found = result { problem = nil }
            finding = false
        }
    }
}
